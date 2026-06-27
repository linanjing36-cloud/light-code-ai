package dispatcher

import (
	"context"
	"os"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/light-code-ai/eion-tools/internal/logging"
	"github.com/light-code-ai/eion-tools/internal/tool"
	hermes "github.com/light-code-ai/eion-tools/proto/gen"
)

func TestMain(m *testing.M) {
	logging.Init()
	os.Exit(m.Run())
}

// Step 3.3: Go 工具 panic 被 Panic_Guard 捕获, 返回结构化 ToolExecResponse.error
func TestDispatch_ToolPanicRecovered(t *testing.T) {
	d := New()
	d.ToolWrapper().Register("panic_tool", "test panic", `{}`, func(_ context.Context, _ string) (string, error) {
		panic("simulated tool panic")
	})

	req := &hermes.AgentRequest{
		Payload: &hermes.AgentRequest_ToolExec{
			ToolExec: &hermes.ToolExecRequest{
				ReqId:         "panic-req-1",
				ToolName:      "panic_tool",
				ArgumentsJson: `{}`,
			},
		},
	}

	resp := d.Dispatch(context.Background(), req)
	te := resp.GetToolExec()
	if te == nil {
		t.Fatal("expected ToolExec response")
	}
	if !strings.Contains(te.GetError(), "panic:") {
		t.Fatalf("expected panic error, got: %#v", te)
	}
}

// Step 3.3: 相同 ReqId 第二次命中幂等缓存, 不重复执行副作用
func TestDispatch_ToolIdempotentCache(t *testing.T) {
	d := New()
	var calls atomic.Int32
	d.ToolWrapper().Register("counter_tool", "count calls", `{}`, func(_ context.Context, _ string) (string, error) {
		calls.Add(1)
		return `{"n":1}`, nil
	})

	reqId := "idem-req-1"
	makeReq := func() *hermes.AgentRequest {
		return &hermes.AgentRequest{
			Payload: &hermes.AgentRequest_ToolExec{
				ToolExec: &hermes.ToolExecRequest{
					ReqId:         reqId,
					ToolName:      "counter_tool",
					ArgumentsJson: `{}`,
				},
			},
		}
	}

	r1 := d.Dispatch(context.Background(), makeReq())
	r2 := d.Dispatch(context.Background(), makeReq())

	if calls.Load() != 1 {
		t.Fatalf("expected handler called once, got %d", calls.Load())
	}
	if r1.GetToolExec().GetResultJson() != r2.GetToolExec().GetResultJson() {
		t.Fatalf("cached result mismatch: %q vs %q",
			r1.GetToolExec().GetResultJson(), r2.GetToolExec().GetResultJson())
	}
}

// 空 ReqId 不走缓存, 每次均执行
func TestDispatch_ToolNoCacheWithoutReqId(t *testing.T) {
	d := New()
	var calls atomic.Int32
	d.ToolWrapper().Register("no_id_tool", "no cache", `{}`, func(_ context.Context, _ string) (string, error) {
		calls.Add(1)
		return `{}`, nil
	})

	req := &hermes.AgentRequest{
		Payload: &hermes.AgentRequest_ToolExec{
			ToolExec: &hermes.ToolExecRequest{
				ToolName:      "no_id_tool",
				ArgumentsJson: `{}`,
			},
		},
	}

	d.Dispatch(context.Background(), req)
	d.Dispatch(context.Background(), req)

	if calls.Load() != 2 {
		t.Fatalf("expected handler called twice without req_id, got %d", calls.Load())
	}
}

func TestDispatch_ToolList(t *testing.T) {
	d := New()
	name, desc, params, handler := tool.GetWeatherHandler()
	d.ToolWrapper().Register(name, desc, params, handler)

	resp := d.Dispatch(context.Background(), &hermes.AgentRequest{
		Payload: &hermes.AgentRequest_ToolList{ToolList: &hermes.ToolListRequest{}},
	})
	tl := resp.GetToolList()
	if tl == nil {
		t.Fatal("expected tool_list response")
	}
	if len(tl.GetTools()) != 1 {
		t.Fatalf("expected 1 tool, got %d", len(tl.GetTools()))
	}
	if tl.GetTools()[0].GetName() != "get_weather" {
		t.Fatalf("unexpected tool name: %s", tl.GetTools()[0].GetName())
	}
}
