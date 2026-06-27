package brain

import (
	"fmt"

	"google.golang.org/protobuf/proto"

	panelpb "hermes/proto/gen/panelpb/proto"
)

func encodePanelRequest(id uint64, method string, args map[string]any) ([]byte, error) {
	argsBytes, err := encodePanelArgs(method, args)
	if err != nil {
		return nil, err
	}
	frame := &panelpb.PanelFrame{
		Payload: &panelpb.PanelFrame_Request{
			Request: &panelpb.PanelRequest{
				Id:        id,
				Method:    method,
				ArgsBytes: argsBytes,
			},
		},
	}
	return proto.Marshal(frame)
}

func encodePanelArgs(method string, args map[string]any) ([]byte, error) {
	if args == nil {
		args = map[string]any{}
	}
	switch method {
	case "start_session":
		msg := &panelpb.StartSessionArgs{
			SystemPrompt: stringArg(args, "system_prompt"),
		}
		return proto.Marshal(msg)
	case "send":
		msg := &panelpb.SendArgs{
			SessionId: stringArg(args, "session_id"),
			Message:   stringArg(args, "message"),
		}
		return proto.Marshal(msg)
	case "approve":
		msg := &panelpb.ApproveArgs{
			ReqId: stringArg(args, "req_id"),
			Allow: boolArg(args, "allow"),
		}
		return proto.Marshal(msg)
	case "brain_status":
		msg := &panelpb.BrainStatusArgs{
			SessionId: stringArg(args, "session_id"),
		}
		return proto.Marshal(msg)
	case "get_history":
		msg := &panelpb.GetHistoryArgs{
			SessionId: stringArg(args, "session_id"),
		}
		return proto.Marshal(msg)
	case "list_tools", "stop":
		return nil, nil
	default:
		return nil, fmt.Errorf("unknown method: %s", method)
	}
}

func decodePanelResponse(method string, resp *panelpb.PanelResponse) (any, error) {
	if resp == nil {
		return nil, fmt.Errorf("empty response")
	}
	if errMsg := resp.GetError(); errMsg != "" {
		return nil, fmt.Errorf("%s", errMsg)
	}
	return decodePanelResult(method, resp.GetResultBytes())
}

func decodePanelResult(method string, bin []byte) (any, error) {
	switch method {
	case "start_session":
		var msg panelpb.StartSessionResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return map[string]any{"session_id": msg.GetSessionId()}, nil
	case "send":
		var msg panelpb.SendResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return map[string]any{"stream_id": msg.GetStreamId()}, nil
	case "list_tools":
		var msg panelpb.ListToolsResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		tools := make([]map[string]any, 0, len(msg.GetTools()))
		for _, t := range msg.GetTools() {
			tools = append(tools, map[string]any{
				"name":            t.GetName(),
				"description":     t.GetDescription(),
				"parameters_json": t.GetParametersJson(),
			})
		}
		return map[string]any{"tools": tools}, nil
	case "approve":
		var msg panelpb.ApproveResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return map[string]any{"ok": msg.GetOk()}, nil
	case "brain_status":
		var msg panelpb.BrainStatusResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return map[string]any{
			"state":       msg.GetState(),
			"loop_count":  msg.GetLoopCount(),
			"max_loops":   msg.GetMaxLoops(),
			"history_len": msg.GetHistoryLen(),
		}, nil
	case "get_history":
		var msg panelpb.GetHistoryResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		msgs := make([]map[string]any, 0, len(msg.GetMessages()))
		for _, e := range msg.GetMessages() {
			msgs = append(msgs, map[string]any{
				"role":            e.GetRole(),
				"content":         e.GetContent(),
				"tool_calls_json": e.GetToolCallsJson(),
				"tool_call_id":    e.GetToolCallId(),
			})
		}
		return map[string]any{"messages": msgs}, nil
	case "stop":
		var msg panelpb.StopResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return map[string]any{"ok": msg.GetOk()}, nil
	default:
		return nil, fmt.Errorf("unknown method: %s", method)
	}
}

func stringArg(args map[string]any, key string) string {
	v, ok := args[key]
	if !ok || v == nil {
		return ""
	}
	switch s := v.(type) {
	case string:
		return s
	default:
		return fmt.Sprint(v)
	}
}

func boolArg(args map[string]any, key string) bool {
	v, ok := args[key]
	if !ok || v == nil {
		return false
	}
	b, _ := v.(bool)
	return b
}

// StreamEvent 是 panel_server 推送到 Wails 前端的流式事件 (经 Wails EmitEvent 广播)。
type StreamEvent struct {
	StreamID string         `json:"stream_id"`
	Kind     string         `json:"kind"` // chunk | tool_event | final | error
	Payload  map[string]any `json:"payload"`
}

func decodePanelStreamEvent(stream *panelpb.PanelStream) StreamEvent {
	ev := StreamEvent{
		StreamID: stream.GetStreamId(),
		Payload:  map[string]any{},
	}
	if chunk := stream.GetChunk(); chunk != nil {
		ev.Kind = "chunk"
		ev.Payload["content"] = chunk.GetContent()
		ev.Payload["reasoning_content"] = chunk.GetReasoningContent()
		return ev
	}
	if te := stream.GetToolEvent(); te != nil {
		ev.Kind = "tool_event"
		ev.Payload["tool_call_id"] = te.GetToolCallId()
		ev.Payload["name"] = te.GetName()
		ev.Payload["arguments_json"] = te.GetArgumentsJson()
		ev.Payload["result_json"] = te.GetResultJson()
		ev.Payload["error"] = te.GetError()
		ev.Payload["finished"] = te.GetFinished()
		return ev
	}
	if fin := stream.GetFinal(); fin != nil {
		ev.Kind = "final"
		ev.Payload["content"] = fin.GetContent()
		ev.Payload["prompt_tokens"] = fin.GetPromptTokens()
		ev.Payload["completion_tokens"] = fin.GetCompletionTokens()
		ev.Payload["loop_count"] = fin.GetLoopCount()
		return ev
	}
	if err := stream.GetError(); err != nil {
		ev.Kind = "error"
		ev.Payload["message"] = err.GetMessage()
		return ev
	}
	ev.Kind = "unknown"
	return ev
}
