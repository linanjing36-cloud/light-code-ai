package broker

import (
	"context"
	"errors"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/light-code-ai/eion-tools/internal/logging"
)

func TestMain(m *testing.M) {
	logging.Init()
	os.Exit(m.Run())
}

// 正常执行：返回结果，统计 +1
func TestBroker_ExecuteSuccess(t *testing.T) {
	b := New()
	h := func(ctx context.Context, args string) (string, error) {
		return `{"echo":"` + args + `"}`, nil
	}
	r := b.Execute(context.Background(), h, "echo_tool", "hello", ExecOptions{ReqId: "r1"})
	if r.Error != "" {
		t.Fatalf("unexpected error: %s", r.Error)
	}
	if r.ResultJSON != `{"echo":"hello"}` {
		t.Fatalf("unexpected result: %s", r.ResultJSON)
	}
	if r.TimedOut || r.Canceled {
		t.Fatalf("should not be timed out or canceled")
	}
	if r.Duration < 0 {
		t.Fatalf("duration should be non-negative, got %s", r.Duration)
	}

	s := b.Stats()
	if s.TotalExecs != 1 || s.TotalSuccess != 1 {
		t.Fatalf("expected 1 exec 1 success, got %+v", s)
	}
	if s.TotalTimeout != 0 || s.TotalCanceled != 0 || s.TotalErrors != 0 {
		t.Fatalf("expected 0 timeout/cancel/error, got %+v", s)
	}
}

// handler 返回 error
func TestBroker_ExecuteError(t *testing.T) {
	b := New()
	h := func(ctx context.Context, args string) (string, error) {
		return "", errors.New("boom")
	}
	r := b.Execute(context.Background(), h, "err_tool", "{}", ExecOptions{ReqId: "r2"})
	if r.Error != "boom" {
		t.Fatalf("expected error 'boom', got %q", r.Error)
	}
	if r.ResultJSON != "" {
		t.Fatalf("expected empty result, got %s", r.ResultJSON)
	}
	if r.TimedOut || r.Canceled {
		t.Fatalf("should not be timed out or canceled")
	}
	s := b.Stats()
	if s.TotalErrors != 1 || s.TotalSuccess != 0 {
		t.Fatalf("expected 1 error 0 success, got %+v", s)
	}
}

// 超时
func TestBroker_ExecuteTimeout(t *testing.T) {
	b := NewWithTimeout(50 * time.Millisecond)
	h := func(ctx context.Context, args string) (string, error) {
		select {
		case <-time.After(500 * time.Millisecond):
			return `{"ok":true}`, nil
		case <-ctx.Done():
			return "", ctx.Err()
		}
	}
	r := b.Execute(context.Background(), h, "slow_tool", "{}", ExecOptions{ReqId: "r3"})
	if !r.TimedOut {
		t.Fatalf("expected timeout, got error=%q", r.Error)
	}
	if r.ResultJSON != "" {
		t.Fatalf("expected empty result on timeout, got %s", r.ResultJSON)
	}
	s := b.Stats()
	if s.TotalTimeout != 1 {
		t.Fatalf("expected 1 timeout, got %+v", s)
	}
}

// ExecOptions.Timeout 覆盖 Broker 默认超时
func TestBroker_ExecOptionsOverrideTimeout(t *testing.T) {
	b := NewWithTimeout(10 * time.Second) // 长默认超时
	h := func(ctx context.Context, args string) (string, error) {
		<-ctx.Done()
		return "", ctx.Err()
	}
	r := b.Execute(context.Background(), h, "override_tool", "{}", ExecOptions{
		ReqId:   "r-override",
		Timeout: 30 * time.Millisecond,
	})
	if !r.TimedOut {
		t.Fatalf("expected timeout from opts, got error=%q", r.Error)
	}
}

// 外部 Cancel 取消正在执行的请求
func TestBroker_Cancel(t *testing.T) {
	b := New()
	started := make(chan struct{})
	h := func(ctx context.Context, args string) (string, error) {
		close(started)
		<-ctx.Done()
		return "", ctx.Err()
	}

	var wg sync.WaitGroup
	wg.Add(1)
	var r ExecResult
	go func() {
		defer wg.Done()
		r = b.Execute(context.Background(), h, "cancellable_tool", "{}", ExecOptions{ReqId: "rc"})
	}()

	<-started
	// 给 Execute 一点时间把 CancelFunc 注册到 pending
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if len(b.Pending()) == 1 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if len(b.Pending()) != 1 {
		t.Fatalf("expected 1 pending, got %d", len(b.Pending()))
	}
	if !b.Cancel("rc") {
		t.Fatalf("expected Cancel to return true")
	}
	wg.Wait()

	if !r.Canceled {
		t.Fatalf("expected canceled, got error=%q", r.Error)
	}
	// 取消后从 pending 清除
	if len(b.Pending()) != 0 {
		t.Fatalf("expected 0 pending after cancel, got %d", len(b.Pending()))
	}
	s := b.Stats()
	if s.TotalCanceled != 1 {
		t.Fatalf("expected 1 canceled, got %+v", s)
	}
}

// Cancel 不存在的 reqId 返回 false
func TestBroker_CancelNotFound(t *testing.T) {
	b := New()
	if b.Cancel("nonexistent") {
		t.Fatalf("expected Cancel to return false for nonexistent reqId")
	}
	if b.Cancel("") {
		t.Fatalf("expected Cancel to return false for empty reqId")
	}
}

// CancelAll 取消所有请求
func TestBroker_CancelAll(t *testing.T) {
	b := New()
	const n = 3
	started := make(chan struct{}, n)
	var ready int32
	h := func(ctx context.Context, args string) (string, error) {
		atomic.AddInt32(&ready, 1)
		started <- struct{}{}
		<-ctx.Done()
		return "", ctx.Err()
	}

	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			b.Execute(context.Background(), h, "tool", "{}", ExecOptions{
				ReqId: "all-" + string(rune('a'+i)),
			})
		}(i)
	}

	// 等所有 handler 启动
	for i := 0; i < n; i++ {
		<-started
	}
	// 等所有 CancelFunc 注册
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if len(b.Pending()) == n {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if got := len(b.Pending()); got != n {
		t.Fatalf("expected %d pending, got %d", n, got)
	}

	cancelCount := b.CancelAll()
	if cancelCount != n {
		t.Fatalf("expected CancelAll to return %d, got %d", n, cancelCount)
	}
	wg.Wait()

	s := b.Stats()
	if s.TotalCanceled != n {
		t.Fatalf("expected %d canceled, got %+v", n, s)
	}
}

// 无 ReqId 时不进入 pending，无法被 Cancel
func TestBroker_NoReqIdNotInPending(t *testing.T) {
	b := New()
	block := make(chan struct{})
	h := func(ctx context.Context, args string) (string, error) {
		<-block
		return `ok`, nil
	}

	done := make(chan ExecResult, 1)
	go func() {
		done <- b.Execute(context.Background(), h, "tool", "{}", ExecOptions{})
	}()

	// 给 Execute 一点时间，确认无 ReqId 不进 pending
	time.Sleep(50 * time.Millisecond)
	if len(b.Pending()) != 0 {
		t.Fatalf("expected 0 pending without reqId, got %d", len(b.Pending()))
	}
	close(block)
	r := <-done
	if r.Error != "" {
		t.Fatalf("unexpected error: %s", r.Error)
	}
}

// Pending 返回当前正在执行的 ReqId 列表
func TestBroker_Pending(t *testing.T) {
	b := New()
	block := make(chan struct{})
	h := func(ctx context.Context, args string) (string, error) {
		<-block
		return `ok`, nil
	}

	const n = 2
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			b.Execute(context.Background(), h, "tool", "{}", ExecOptions{
				ReqId: "p-" + string(rune('a'+i)),
			})
		}(i)
	}

	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if len(b.Pending()) == n {
			break
		}
		time.Sleep(time.Millisecond)
	}
	pending := b.Pending()
	if len(pending) != n {
		t.Fatalf("expected %d pending, got %d (%v)", n, len(pending), pending)
	}
	// 验证 reqId 在返回值中
	seen := map[string]bool{}
	for _, id := range pending {
		seen[id] = true
	}
	if !seen["p-a"] || !seen["p-b"] {
		t.Fatalf("expected p-a and p-b in pending, got %v", pending)
	}

	close(block)
	wg.Wait()
	if len(b.Pending()) != 0 {
		t.Fatalf("expected 0 pending after completion, got %d", len(b.Pending()))
	}
}

// 父 context 取消会传播到 handler
func TestBroker_ParentContextCancel(t *testing.T) {
	b := New()
	parentCtx, parentCancel := context.WithCancel(context.Background())
	started := make(chan struct{})
	h := func(ctx context.Context, args string) (string, error) {
		close(started)
		<-ctx.Done()
		return "", ctx.Err()
	}

	var wg sync.WaitGroup
	wg.Add(1)
	var r ExecResult
	go func() {
		defer wg.Done()
		r = b.Execute(parentCtx, h, "tool", "{}", ExecOptions{ReqId: "parent-cancel"})
	}()

	<-started
	parentCancel()
	wg.Wait()

	if !r.Canceled {
		t.Fatalf("expected canceled, got error=%q timed_out=%v", r.Error, r.TimedOut)
	}
}

// NewWithTimeout <= 0 回退到 DefaultTimeout
func TestBroker_NewWithTimeoutInvalid(t *testing.T) {
	b := NewWithTimeout(0)
	if b.timeout != DefaultTimeout {
		t.Fatalf("expected default timeout, got %s", b.timeout)
	}
	b2 := NewWithTimeout(-1)
	if b2.timeout != DefaultTimeout {
		t.Fatalf("expected default timeout, got %s", b2.timeout)
	}
}

// Stats 反映多次执行
func TestBroker_StatsMultipleExecs(t *testing.T) {
	b := New()
	h := func(ctx context.Context, args string) (string, error) {
		return `ok`, nil
	}
	errH := func(ctx context.Context, args string) (string, error) {
		return "", errors.New("err")
	}
	b.Execute(context.Background(), h, "ok_tool", "{}", ExecOptions{})
	b.Execute(context.Background(), h, "ok_tool", "{}", ExecOptions{})
	b.Execute(context.Background(), errH, "err_tool", "{}", ExecOptions{})

	s := b.Stats()
	if s.TotalExecs != 3 {
		t.Fatalf("expected 3 execs, got %d", s.TotalExecs)
	}
	if s.TotalSuccess != 2 {
		t.Fatalf("expected 2 success, got %d", s.TotalSuccess)
	}
	if s.TotalErrors != 1 {
		t.Fatalf("expected 1 error, got %d", s.TotalErrors)
	}
}
