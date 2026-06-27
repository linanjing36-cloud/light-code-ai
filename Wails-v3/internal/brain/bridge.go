// Package brain 是 Wails(Go) 与 Agent-brains(Erlang/OTP) 之间的桥接层。
//
// 通信协议 (Step 1.4 / panel.proto):
//   4 字节大端长度 + PanelFrame Protobuf
//   请求 PanelFrame.request / 响应 PanelFrame.response / 流式 PanelFrame.stream
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
)

type Bridge struct {
	mu      sync.Mutex
	ctx     context.Context
	cancel  context.CancelFunc
	started bool

	addr     string
	poolSize int
	conns    []net.Conn
	queue    chan pendingCall

	reqSeq atomic.Uint64
}

type pendingCall struct {
	id     uint64
	method string
	body   []byte
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

	b.queue = make(chan pendingCall, 64)
	b.conns = make([]net.Conn, 0, b.poolSize)
	for i := 0; i < b.poolSize; i++ {
		conn, err := dialPanel(addr, dialTimeout)
		if err != nil {
			log.Printf("[brain] pool slot %d/%d connect failed: %v", i+1, b.poolSize, err)
			go b.reconnectLoop(ctx)
			continue
		}
		b.conns = append(b.conns, conn)
		go b.connWorker(ctx, conn, bufio.NewReaderSize(conn, 64*1024))
	}
	if len(b.conns) == 0 {
		go b.reconnectLoop(ctx)
	} else {
		log.Printf("[brain] connection pool ready: %d/%d", len(b.conns), b.poolSize)
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
	for _, conn := range b.conns {
		_ = conn.Close()
	}
	if b.queue != nil {
		close(b.queue)
	}
	b.conns = nil
	b.queue = nil
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
	b.mu.Lock()
	q := b.queue
	b.mu.Unlock()
	if q == nil {
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
	case q <- pc:
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
		return nil, fmt.Errorf("brain: request queue full")
	}

	select {
	case resp := <-ch:
		return resp.result, resp.err
	case <-ctx.Done():
		return nil, fmt.Errorf("brain: %s: %w", method, ctx.Err())
	case <-time.After(30 * time.Second):
		return nil, fmt.Errorf("brain: %s: timeout (30s)", method)
	}
}

// connWorker: 从全局队列取请求, 在本连接上写帧, 读帧直到匹配 id (跳过 stream push)。
func (b *Bridge) connWorker(ctx context.Context, conn net.Conn, reader *bufio.Reader) {
	remote := conn.RemoteAddr().String()
	go func() {
		<-ctx.Done()
		_ = conn.Close()
	}()

	for req := range b.queue {
		if _, err := conn.Write(req.body); err != nil {
			req.ch <- callResult{err: fmt.Errorf("write: %w", err)}
			b.markConnBroken(conn, remote)
			return
		}

		var result callResult
		for {
			frame, err := readPanelFrame(reader)
			if err != nil {
				result = callResult{err: fmt.Errorf("read: %w", err)}
				b.markConnBroken(conn, remote)
				req.ch <- result
				return
			}
			if resp := frame.GetResponse(); resp != nil {
				if resp.GetId() == req.id {
					r, decErr := decodePanelResponse(req.method, resp)
					result = callResult{result: r, err: decErr}
					break
				}
				log.Printf("[brain] worker skip orphan response id=%d want=%d", resp.GetId(), req.id)
				continue
			}
			if stream := frame.GetStream(); stream != nil {
				emitPanelStream(stream)
				continue
			}
		}
		req.ch <- result
	}
}

func (b *Bridge) markConnBroken(conn net.Conn, remote string) {
	b.mu.Lock()
	for i, c := range b.conns {
		if c == conn {
			b.conns = append(b.conns[:i], b.conns[i+1:]...)
			break
		}
	}
	ctx := b.ctx
	b.mu.Unlock()
	_ = conn.Close()
	if ctx != nil && ctx.Err() == nil {
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
		if len(b.conns) >= b.poolSize {
			b.mu.Unlock()
			return
		}
		b.mu.Unlock()

		conn, err := dialPanel(addr, dialTimeout)
		if err != nil {
			continue
		}

		b.mu.Lock()
		if b.ctx == nil || b.ctx.Err() != nil {
			b.mu.Unlock()
			_ = conn.Close()
			return
		}
		b.conns = append(b.conns, conn)
		b.mu.Unlock()

		go b.connWorker(ctx, conn, bufio.NewReaderSize(conn, 64*1024))
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
