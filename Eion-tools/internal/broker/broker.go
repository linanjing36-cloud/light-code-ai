// Package broker 提供统一的能力执行出口，在 dispatcher 与 tool wrapper 之间增加一层治理。
//
// 设计目标（EXEC-P0-002）：
//   - 统一执行出口：所有能力调用（tool/skill/mcp/plugin）都经过 broker
//   - 超时控制：每个执行有超时限制，防止长时间阻塞 Erlang 端口
//   - 取消机制：可按 ReqId 取消正在执行的能力调用
//   - 执行追踪：记录执行的开始/结束/状态/耗时，供观测与审计
//
// 设计原则：
//   - 不持有会话状态，仅持有 pending 执行的 CancelFunc 映射
//   - 不做重试、不做编排 —— 这些交给 Erlang
//   - 与 tool.HandlerFunc 签名兼容，零侵入接入
package broker

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/light-code-ai/eion-tools/internal/logging"
	"go.uber.org/zap"
)

// DefaultTimeout 默认执行超时（30 秒），与 Erlang 侧 panel exec 超时对齐。
const DefaultTimeout = 30 * time.Second

// Handler 能力执行函数，与 tool.HandlerFunc 签名一致。
type Handler func(ctx context.Context, argumentsJSON string) (resultJSON string, err error)

// ExecOptions 执行选项。
type ExecOptions struct {
	// Timeout 执行超时，0 表示使用 Broker 默认超时。
	Timeout time.Duration
	// ReqId 幂等 ID，同时作为取消键。为空时不支持外部取消。
	ReqId string
}

// ExecResult 执行结果。
type ExecResult struct {
	ResultJSON string
	Error      string
	Duration   time.Duration
	TimedOut   bool
	Canceled   bool
}

// Trace 执行轨迹记录。
type Trace struct {
	ReqId    string
	Name     string
	StartAt  time.Time
	EndAt    time.Time
	Duration time.Duration
	Status   TraceStatus
	Error    string
}

// TraceStatus 执行状态。
type TraceStatus string

const (
	StatusRunning  TraceStatus = "running"
	StatusSuccess  TraceStatus = "success"
	StatusTimeout  TraceStatus = "timeout"
	StatusCanceled TraceStatus = "canceled"
	StatusError    TraceStatus = "error"
)

// Broker 统一执行出口，提供超时、取消、追踪。
type Broker struct {
	mu      sync.RWMutex
	pending map[string]context.CancelFunc // ReqId -> CancelFunc
	timeout time.Duration                 // 默认超时

	// 统计计数器（原子操作）
	totalExecs    int64
	totalSuccess  int64
	totalTimeout  int64
	totalCanceled int64
	totalErrors   int64
}

// New 创建 Broker，使用 DefaultTimeout。
func New() *Broker {
	return &Broker{
		pending: make(map[string]context.CancelFunc),
		timeout: DefaultTimeout,
	}
}

// NewWithTimeout 创建 Broker，指定默认超时。
func NewWithTimeout(timeout time.Duration) *Broker {
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	return &Broker{
		pending: make(map[string]context.CancelFunc),
		timeout: timeout,
	}
}

// Execute 统一执行入口：在超时/取消保护下执行 handler，返回 ExecResult。
//
// 执行流程：
//  1. 解析超时（opts.Timeout > 0 优先，否则用 Broker 默认值）
//  2. 创建带超时的 context
//  3. 若 ReqId 非空，注册 CancelFunc 到 pending map
//  4. 执行 handler
//  5. 清理 pending map
//  6. 记录统计与 trace
func (b *Broker) Execute(ctx context.Context, h Handler, name, args string, opts ExecOptions) ExecResult {
	start := time.Now()
	atomic.AddInt64(&b.totalExecs, 1)

	timeout := opts.Timeout
	if timeout <= 0 {
		timeout = b.timeout
	}

	// 创建带超时的 context
	execCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	// 注册到 pending map（支持外部取消）
	reqId := opts.ReqId
	if reqId != "" {
		b.mu.Lock()
		b.pending[reqId] = cancel
		b.mu.Unlock()
		defer func() {
			b.mu.Lock()
			delete(b.pending, reqId)
			b.mu.Unlock()
		}()
	}

	// 执行 handler
	result, err := h(execCtx, args)
	duration := time.Since(start)

	// 构造返回值
	ret := ExecResult{Duration: duration}

	if err != nil {
		ret.Error = err.Error()
		switch {
		case execCtx.Err() == context.DeadlineExceeded:
			ret.TimedOut = true
			ret.Error = fmt.Sprintf("capability %s timed out after %s", name, timeout)
			atomic.AddInt64(&b.totalTimeout, 1)
			logging.Logger.Warn("broker exec timeout",
				zap.String("name", name),
				zap.String("req_id", reqId),
				zap.Duration("timeout", timeout))
		case execCtx.Err() == context.Canceled:
			ret.Canceled = true
			ret.Error = fmt.Sprintf("capability %s canceled", name)
			atomic.AddInt64(&b.totalCanceled, 1)
			logging.Logger.Info("broker exec canceled",
				zap.String("name", name),
				zap.String("req_id", reqId))
		default:
			atomic.AddInt64(&b.totalErrors, 1)
			logging.Logger.Error("broker exec error",
				zap.String("name", name),
				zap.String("req_id", reqId),
				zap.Error(err),
				zap.Duration("duration", duration))
		}
		return ret
	}

	// 成功
	ret.ResultJSON = result
	atomic.AddInt64(&b.totalSuccess, 1)
	logging.Logger.Debug("broker exec success",
		zap.String("name", name),
		zap.String("req_id", reqId),
		zap.Duration("duration", duration))

	return ret
}

// Cancel 取消正在执行的请求。返回是否找到并取消了该请求。
func (b *Broker) Cancel(reqId string) bool {
	if reqId == "" {
		return false
	}
	b.mu.RLock()
	cancel, ok := b.pending[reqId]
	b.mu.RUnlock()
	if !ok {
		return false
	}
	cancel()
	return true
}

// CancelAll 取消所有正在执行的请求。
func (b *Broker) CancelAll() int {
	b.mu.RLock()
	defer b.mu.RUnlock()
	count := 0
	for _, cancel := range b.pending {
		cancel()
		count++
	}
	return count
}

// Pending 返回当前正在执行的 ReqId 列表。
func (b *Broker) Pending() []string {
	b.mu.RLock()
	defer b.mu.RUnlock()
	out := make([]string, 0, len(b.pending))
	for reqId := range b.pending {
		out = append(out, reqId)
	}
	return out
}

// Stats 返回执行统计快照。
type Stats struct {
	TotalExecs    int64
	TotalSuccess  int64
	TotalTimeout  int64
	TotalCanceled int64
	TotalErrors   int64
	PendingCount  int
}

// Stats 返回当前统计快照。
func (b *Broker) Stats() Stats {
	b.mu.RLock()
	pendingCount := len(b.pending)
	b.mu.RUnlock()
	return Stats{
		TotalExecs:    atomic.LoadInt64(&b.totalExecs),
		TotalSuccess:  atomic.LoadInt64(&b.totalSuccess),
		TotalTimeout:  atomic.LoadInt64(&b.totalTimeout),
		TotalCanceled: atomic.LoadInt64(&b.totalCanceled),
		TotalErrors:   atomic.LoadInt64(&b.totalErrors),
		PendingCount:  pendingCount,
	}
}
