// Package brain 是 Wails(Go) 与 Agent-brains(Erlang/OTP) 之间的桥接层。
//
// 通信协议 (Step 1.4 / panel.proto):
//   4 字节大端长度 + PanelFrame Protobuf
//   请求 PanelFrame.request / 响应 PanelFrame.response / 流式 PanelFrame.stream
//
// 异步模型 (与架构 §3.1 对齐):
//   - 每连接独立 reader goroutine 持续读帧, 按 req id 路由 PanelResponse
//   - PanelStream 帧异步 EmitEvent("panel:stream"), 不阻塞 RPC 调用方
//   - send 收到 stream_id 即返回; chunk/final 由前端事件驱动
package brain

import (
	"bufio"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/wailsapp/wails/v3/pkg/application"
	"google.golang.org/protobuf/proto"

	panelpb "hermes/proto/gen/panelpb/proto"
)

const (
	defaultPoolSize    = 4
	reconnectDelay     = 2 * time.Second
	dialTimeout        = 5 * time.Second
	addrResolveTimeout = 30 * time.Second
	defaultRPCDeadline = 30 * time.Second
)

type Bridge struct {
	mu      sync.Mutex
	ctx     context.Context
	cancel  context.CancelFunc
	started bool

	addr     string
	poolSize int
	slots    []*connSlot

	reqSeq atomic.Uint64
	next   atomic.Uint64
}

type connSlot struct {
	conn net.Conn
	reqQ chan pendingCall

	writeMu sync.Mutex
}

type pendingCall struct {
	id     uint64
	method string
	body   []byte
	ch     chan callResult
}

type pendingReply struct {
	method string
	ch     chan callResult
}

type callResult struct {
	result any
	err    error
}

func NewBridge() *Bridge {
	return &Bridge{poolSize: defaultPoolSize}
}

func (b *Bridge) ServiceStartup(ctx context.Context, _ application.ServiceOptions) error {
	return b.Start(ctx)
}

func (b *Bridge) ServiceShutdown() error {
	b.Stop()
	return nil
}

func (b *Bridge) Start(parentCtx context.Context) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.started {
		return nil
	}

	ctx, cancel := context.WithCancel(parentCtx)
	b.ctx, b.cancel = ctx, cancel

	addr, err := resolvePanelAddr(ctx, addrResolveTimeout)
	if err != nil {
		cancel()
		return fmt.Errorf("brain: 发现 panel_server 地址失败: %w", err)
	}
	b.addr = addr
	log.Printf("[brain] panel_server addr resolved: %s", addr)

	b.slots = make([]*connSlot, 0, b.poolSize)
	for i := 0; i < b.poolSize; i++ {
		conn, err := dialPanel(addr, dialTimeout)
		if err != nil {
			log.Printf("[brain] pool slot %d/%d connect failed: %v", i+1, b.poolSize, err)
			continue
		}
		slot := &connSlot{
			conn: conn,
			reqQ: make(chan pendingCall, 16),
		}
		b.slots = append(b.slots, slot)
		go b.runConn(ctx, slot)
	}
	if len(b.slots) == 0 {
		go b.reconnectLoop(ctx)
	} else {
		log.Printf("[brain] connection pool ready: %d/%d", len(b.slots), b.poolSize)
	}

	b.started = true
	return nil
}

func (b *Bridge) Stop() {
	b.mu.Lock()
	if !b.started {
		b.mu.Unlock()
		return
	}
	b.mu.Unlock()

	stopCtx, stopCancel := context.WithTimeout(context.Background(), 3*time.Second)
	_, _ = b.callInternal(stopCtx, "stop", nil)
	stopCancel()

	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cancel != nil {
		b.cancel()
	}
	for _, slot := range b.slots {
		close(slot.reqQ)
		_ = slot.conn.Close()
	}
	b.slots = nil
	b.started = false
}

func (b *Bridge) Call(method string, args map[string]any) (any, error) {
	b.mu.Lock()
	started := b.started
	b.mu.Unlock()
	if !started {
		return nil, fmt.Errorf("brain: not started")
	}
	return b.callInternal(context.Background(), method, args)
}

func (b *Bridge) callInternal(ctx context.Context, method string, args map[string]any) (any, error) {
	slot := b.pickSlot()
	if slot == nil {
		return nil, fmt.Errorf("brain: connection pool closed")
	}

	id := b.reqSeq.Add(1)
	frameBin, err := encodePanelRequest(id, method, args)
	if err != nil {
		return nil, fmt.Errorf("brain: encode request: %w", err)
	}
	frame := make([]byte, 4+len(frameBin))
	binary.BigEndian.PutUint32(frame[:4], uint32(len(frameBin)))
	copy(frame[4:], frameBin)

	ch := make(chan callResult, 1)
	pc := pendingCall{id: id, method: method, body: frame, ch: ch}

	select {
	case slot.reqQ <- pc:
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
		return nil, fmt.Errorf("brain: request queue full")
	}

	deadline := rpcDeadline(method)
	timer := time.NewTimer(deadline)
	defer timer.Stop()

	select {
	case resp := <-ch:
		return resp.result, resp.err
	case <-ctx.Done():
		return nil, fmt.Errorf("brain: %s: %w", method, ctx.Err())
	case <-timer.C:
		return nil, fmt.Errorf("brain: %s: timeout (%s)", method, deadline)
	}
}

func rpcDeadline(method string) time.Duration {
	if method == "send" {
		// send 只等 PanelResponse(stream_id); 流式终态走 panel:stream 事件
		return defaultRPCDeadline
	}
	return defaultRPCDeadline
}

func (b *Bridge) pickSlot() *connSlot {
	b.mu.Lock()
	slots := b.slots
	b.mu.Unlock()
	if len(slots) == 0 {
		return nil
	}
	i := b.next.Add(1) % uint64(len(slots))
	return slots[i]
}

// runConn: 每连接一个 writer 循环 + 独立 reader goroutine 多路复用响应/流式 push。
func (b *Bridge) runConn(ctx context.Context, slot *connSlot) {
	remote := slot.conn.RemoteAddr().String()
	pending := sync.Map{}

	go b.connReader(ctx, slot, &pending, remote)

	go func() {
		<-ctx.Done()
		_ = slot.conn.Close()
	}()

	for pc := range slot.reqQ {
		pending.Store(pc.id, pendingReply{method: pc.method, ch: pc.ch})

		slot.writeMu.Lock()
		_, err := slot.conn.Write(pc.body)
		slot.writeMu.Unlock()
		if err != nil {
			pending.Delete(pc.id)
			pc.ch <- callResult{err: fmt.Errorf("write: %w", err)}
			b.markSlotBroken(slot, remote)
			return
		}
	}
}

func (b *Bridge) connReader(ctx context.Context, slot *connSlot, pending *sync.Map, remote string) {
	reader := bufio.NewReaderSize(slot.conn, 64*1024)
	for {
		if ctx.Err() != nil {
			return
		}
		frame, err := readPanelFrame(reader)
		if err != nil {
			log.Printf("[brain] reader %s exit: %v", remote, err)
			pending.Range(func(k, v any) bool {
				pr := v.(pendingReply)
				pr.ch <- callResult{err: fmt.Errorf("read: %w", err)}
				pending.Delete(k)
				return true
			})
			b.markSlotBroken(slot, remote)
			return
		}
		if resp := frame.GetResponse(); resp != nil {
			if v, ok := pending.Load(resp.GetId()); ok {
				pr := v.(pendingReply)
				pending.Delete(resp.GetId())
				r, decErr := decodePanelResponse(pr.method, resp)
				pr.ch <- callResult{result: r, err: decErr}
			} else {
				log.Printf("[brain] orphan response id=%d from %s", resp.GetId(), remote)
			}
			continue
		}
		if stream := frame.GetStream(); stream != nil {
			emitPanelStream(stream)
		}
	}
}

func (b *Bridge) markSlotBroken(slot *connSlot, remote string) {
	b.mu.Lock()
	for i, s := range b.slots {
		if s == slot {
			b.slots = append(b.slots[:i], b.slots[i+1:]...)
			break
		}
	}
	ctx := b.ctx
	poolSize := b.poolSize
	needReconnect := len(b.slots) < poolSize
	b.mu.Unlock()

	_ = slot.conn.Close()
	if needReconnect && ctx != nil && ctx.Err() == nil {
		go b.reconnectLoop(ctx)
	}
}

func (b *Bridge) reconnectLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(reconnectDelay):
		}

		b.mu.Lock()
		addr := b.addr
		if len(b.slots) >= b.poolSize {
			b.mu.Unlock()
			return
		}
		b.mu.Unlock()

		conn, err := dialPanel(addr, dialTimeout)
		if err != nil {
			continue
		}

		slot := &connSlot{
			conn: conn,
			reqQ: make(chan pendingCall, 16),
		}

		b.mu.Lock()
		if b.ctx == nil || b.ctx.Err() != nil {
			b.mu.Unlock()
			_ = conn.Close()
			return
		}
		b.slots = append(b.slots, slot)
		b.mu.Unlock()

		go b.runConn(ctx, slot)
	}
}

func readPanelFrame(r *bufio.Reader) (*panelpb.PanelFrame, error) {
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(lenBuf[:])
	body := make([]byte, n)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, err
	}
	var frame panelpb.PanelFrame
	if err := proto.Unmarshal(body, &frame); err != nil {
		return nil, fmt.Errorf("unmarshal PanelFrame: %w", err)
	}
	return &frame, nil
}

func resolvePanelAddr(ctx context.Context, timeout time.Duration) (string, error) {
	if addr := os.Getenv("HERMES_PANEL_ADDR"); addr != "" {
		return addr, nil
	}
	addrFile := os.Getenv("HERMES_PANEL_ADDR_FILE")
	if addrFile == "" {
		addrFile = defaultPanelAddrFile()
	}
	deadline := time.Now().Add(timeout)
	for {
		if data, err := os.ReadFile(addrFile); err == nil && len(data) > 0 {
			return string(data), nil
		}
		if time.Now().After(deadline) {
			return "", fmt.Errorf("timeout waiting for %s", addrFile)
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
}

func defaultPanelAddrFile() string {
	wd, _ := os.Getwd()
	for _, c := range []string{
		filepath.Join(wd, "..", "bin", "run", "panel.addr"),
		filepath.Join(wd, "..", "run", "panel.addr"),
	} {
		if abs, err := filepath.Abs(c); err == nil {
			return abs
		}
	}
	return filepath.Join(wd, "..", "bin", "run", "panel.addr")
}

func emitPanelStream(stream *panelpb.PanelStream) {
	app := application.Get()
	if app == nil {
		return
	}
	w := app.Window.Current()
	if w == nil {
		return
	}
	ev := decodePanelStreamEvent(stream)
	w.EmitEvent("panel:stream", ev)
}
