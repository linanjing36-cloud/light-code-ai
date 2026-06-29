package brain

import (
	"fmt"
	"math"

	"google.golang.org/protobuf/proto"

	panelpb "hermes/proto/gen/panelpb/proto"
)

type StartSessionResult struct {
	SessionID string
}

type SendResult struct {
	StreamID string
}

type ToolDesc struct {
	Name        string
	Description string
	Parameters  any
}

type CapabilityDesc struct {
	Name        string
	Kind        string
	Source      string
	Version     string
	Description string
	InputSchema any
	Streaming   bool
	RiskLevel   string
	CostHint    string
	Tags        []string
}

type PendingApprovalEntry struct {
	ReqID         string `json:"req_id"`
	SessionID     string `json:"session_id"`
	ToolCallID    string `json:"tool_call_id"`
	ToolName      string `json:"tool_name"`
	ArgumentsJSON string `json:"arguments_json,omitempty"`
	RiskLevel     string `json:"risk_level"`
	ExpireMS      int32  `json:"expire_ms"`
	RegisteredAt  int64  `json:"registered_at"`
}

type DebugCapabilityResult struct {
	CapabilityName string
	ResultJSON     string
	Error          string
}

type ToolFunction struct {
	Name      string
	Arguments any
}

type ToolCall struct {
	ID       string
	Type     string
	Function ToolFunction
}

type ApproveResult struct {
	OK bool
}

type BrainStatusResult struct {
	State      string
	LoopCount  int32
	MaxLoops   int32
	HistoryLen int32
}

type HistoryEntry struct {
	Role       string
	Content    string
	ToolCalls  []ToolCall
	ToolCallID string
}

type DeleteSessionResult struct {
	OK bool
}

type StopResult struct {
	OK bool
}

type CancelExecutionResult struct {
	OK bool
}

type ProviderConfig struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	APIBase   string   `json:"api_base"`
	APIKey    string   `json:"api_key,omitempty"`
	Models    []string `json:"models"`
	Enabled   bool     `json:"enabled"`
	IsDefault bool     `json:"is_default"`
	LatencyMS int64    `json:"latency_ms"`
}

type ListProvidersResult struct {
	Providers []ProviderConfig `json:"providers"`
}

type UpsertProviderResult struct {
	OK bool   `json:"ok"`
	ID string `json:"id"`
}

type DeleteProviderResult struct {
	OK bool `json:"ok"`
}

type SetDefaultProviderResult struct {
	OK bool `json:"ok"`
}

type TestProviderResult struct {
	OK        bool   `json:"ok"`
	LatencyMS int64  `json:"latency_ms"`
	Error     string `json:"error"`
}

type RiskPolicy struct {
	RiskLevel string `json:"risk_level"`
	Action    string `json:"action"`
}

type GetRiskPoliciesResult struct {
	Policies []RiskPolicy `json:"policies"`
}

type SetRiskPolicyResult struct {
	OK bool `json:"ok"`
}

type SetSessionProviderResult struct {
	OK bool `json:"ok"`
}

type MemoryEntry struct {
	Key       string `json:"key"`
	Tier      string `json:"tier"`
	Content   string `json:"content"`
	Source    string `json:"source"`
	CreatedAt int64  `json:"created_at"`
	SessionID string `json:"session_id"`
}

type ListMemoriesResult struct {
	Memories []MemoryEntry `json:"memories"`
}

type AddMemoryResult struct {
	OK  bool   `json:"ok"`
	Key string `json:"key"`
}

type DeleteMemoryResult struct {
	OK bool `json:"ok"`
}

type ClearMemoriesResult struct {
	OK    bool  `json:"ok"`
	Count int32 `json:"count"`
}

type PlanStep struct {
	Index       int32  `json:"index"`
	Description string `json:"description"`
	ToolHint    string `json:"tool_hint"`
	RiskLevel   string `json:"risk_level"`
}

type PlanGenerated struct {
	Goal        string     `json:"goal"`
	Steps       []PlanStep `json:"steps"`
	Warnings    []string   `json:"warnings"`
	Suggestions []string   `json:"suggestions"`
}

type PlanStepUpdate struct {
	StepIndex     int32  `json:"step_index"`
	Status        string `json:"status"`
	ResultSummary string `json:"result_summary"`
}

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
			Model:        stringArg(args, "model"),
			ApiKey:       stringArg(args, "api_key"),
			ApiBase:      stringArg(args, "api_base"),
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
	case "debug_capability":
		msg := &panelpb.DebugCapabilityArgs{
			CapabilityName: stringArg(args, "capability_name"),
			ArgumentsJson:  stringArg(args, "arguments_json"),
			TimeoutMs:      uint32(intArg(args, "timeout_ms")),
		}
		return proto.Marshal(msg)
	case "get_history":
		msg := &panelpb.GetHistoryArgs{
			SessionId: stringArg(args, "session_id"),
		}
		return proto.Marshal(msg)
	case "delete_session":
		msg := &panelpb.DeleteSessionArgs{
			SessionId: stringArg(args, "session_id"),
		}
		return proto.Marshal(msg)
	case "cancel_execution":
		msg := &panelpb.CancelExecutionArgs{
			SessionId: stringArg(args, "session_id"),
		}
		return proto.Marshal(msg)
	case "list_providers", "get_risk_policies", "list_tools", "list_capabilities", "list_pending_approvals", "stop":
		return nil, nil
	case "upsert_provider":
		prov := mapArg(args, "provider")
		msg := &panelpb.UpsertProviderArgs{
			Provider: pbProviderConfigFromMap(prov),
		}
		return proto.Marshal(msg)
	case "delete_provider":
		msg := &panelpb.DeleteProviderArgs{
			ProviderId: stringArg(args, "provider_id"),
		}
		return proto.Marshal(msg)
	case "set_default_provider":
		msg := &panelpb.SetDefaultProviderArgs{
			ProviderId: stringArg(args, "provider_id"),
		}
		return proto.Marshal(msg)
	case "test_provider":
		prov := mapArg(args, "provider")
		msg := &panelpb.TestProviderArgs{
			Provider: pbProviderConfigFromMap(prov),
		}
		return proto.Marshal(msg)
	case "set_risk_policy":
		msg := &panelpb.SetRiskPolicyArgs{
			RiskLevel: stringArg(args, "risk_level"),
			Action:    stringArg(args, "action"),
		}
		return proto.Marshal(msg)
	case "set_session_provider":
		msg := &panelpb.SetSessionProviderArgs{
			SessionId:  stringArg(args, "session_id"),
			ProviderId: stringArg(args, "provider_id"),
		}
		return proto.Marshal(msg)
	case "list_memories":
		msg := &panelpb.ListMemoriesArgs{
			SessionId: stringArg(args, "session_id"),
			Tier:      pbMemoryTierFromString(stringArg(args, "tier")),
		}
		return proto.Marshal(msg)
	case "add_memory":
		msg := &panelpb.AddMemoryArgs{
			SessionId: stringArg(args, "session_id"),
			Tier:      pbMemoryTierFromString(stringArg(args, "tier")),
			Content:   stringArg(args, "content"),
		}
		return proto.Marshal(msg)
	case "delete_memory":
		msg := &panelpb.DeleteMemoryArgs{
			SessionId: stringArg(args, "session_id"),
			Tier:      pbMemoryTierFromString(stringArg(args, "tier")),
			Key:       stringArg(args, "key"),
		}
		return proto.Marshal(msg)
	case "clear_memories":
		msg := &panelpb.ClearMemoriesArgs{
			SessionId: stringArg(args, "session_id"),
			Tier:      pbMemoryTierFromString(stringArg(args, "tier")),
		}
		return proto.Marshal(msg)
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
		return StartSessionResult{SessionID: msg.GetSessionId()}, nil
	case "send":
		var msg panelpb.SendResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return SendResult{StreamID: msg.GetStreamId()}, nil
	case "list_tools":
		var msg panelpb.ListToolsResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		tools := make([]ToolDesc, 0, len(msg.GetTools()))
		for _, t := range msg.GetTools() {
			tools = append(tools, ToolDesc{
				Name:        t.GetName(),
				Description: t.GetDescription(),
				Parameters:  decodeToolParametersPB(t.GetParametersPb()),
			})
		}
		return tools, nil
	case "list_capabilities":
		var msg panelpb.ListCapabilitiesResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		caps := make([]CapabilityDesc, 0, len(msg.GetCapabilities()))
		for _, c := range msg.GetCapabilities() {
			caps = append(caps, CapabilityDesc{
				Name:        c.GetName(),
				Kind:        c.GetKind(),
				Source:      c.GetSource(),
				Version:     c.GetVersion(),
				Description: c.GetDescription(),
				InputSchema: decodeToolParametersPB(c.GetInputSchemaPb()),
				Streaming:   c.GetStreaming(),
				RiskLevel:   c.GetRiskLevel(),
				CostHint:    c.GetCostHint(),
				Tags:        append([]string(nil), c.GetTags()...),
			})
		}
		return caps, nil
	case "list_pending_approvals":
		var msg panelpb.ListPendingApprovalsResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		approvals := make([]PendingApprovalEntry, 0, len(msg.GetApprovals()))
		for _, item := range msg.GetApprovals() {
			approvals = append(approvals, PendingApprovalEntry{
				ReqID:         item.GetReqId(),
				SessionID:     item.GetSessionId(),
				ToolCallID:    item.GetToolCallId(),
				ToolName:      item.GetToolName(),
				ArgumentsJSON: item.GetArgumentsJson(),
				RiskLevel:     item.GetRiskLevel(),
				ExpireMS:      item.GetExpireMs(),
				RegisteredAt:  item.GetRegisteredAt(),
			})
		}
		return approvals, nil
	case "debug_capability":
		var msg panelpb.DebugCapabilityResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return DebugCapabilityResult{
			CapabilityName: msg.GetCapabilityName(),
			ResultJSON:     msg.GetResultJson(),
			Error:          msg.GetError(),
		}, nil
	case "approve":
		var msg panelpb.ApproveResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return ApproveResult{OK: msg.GetOk()}, nil
	case "brain_status":
		var msg panelpb.BrainStatusResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return BrainStatusResult{
			State:      msg.GetState(),
			LoopCount:  msg.GetLoopCount(),
			MaxLoops:   msg.GetMaxLoops(),
			HistoryLen: msg.GetHistoryLen(),
		}, nil
	case "get_history":
		var msg panelpb.GetHistoryResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		msgs := make([]HistoryEntry, 0, len(msg.GetMessages()))
		for _, e := range msg.GetMessages() {
			msgs = append(msgs, HistoryEntry{
				Role:       e.GetRole(),
				Content:    e.GetContent(),
				ToolCalls:  pbToolCallsToSlice(e.GetToolCalls()),
				ToolCallID: e.GetToolCallId(),
			})
		}
		return msgs, nil
	case "delete_session":
		var msg panelpb.DeleteSessionResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return DeleteSessionResult{OK: msg.GetOk()}, nil
	case "cancel_execution":
		var msg panelpb.CancelExecutionResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return CancelExecutionResult{OK: msg.GetOk()}, nil
	case "list_providers":
		var msg panelpb.ListProvidersResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		providers := make([]ProviderConfig, 0, len(msg.GetProviders()))
		for _, p := range msg.GetProviders() {
			providers = append(providers, ProviderConfig{
				ID:        p.GetId(),
				Name:      p.GetName(),
				APIBase:   p.GetApiBase(),
				APIKey:    p.GetApiKey(),
				Models:    append([]string(nil), p.GetModels()...),
				Enabled:   p.GetEnabled(),
				IsDefault: p.GetIsDefault(),
				LatencyMS: p.GetLatencyMs(),
			})
		}
		return providers, nil
	case "upsert_provider":
		var msg panelpb.UpsertProviderResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return UpsertProviderResult{OK: msg.GetOk(), ID: msg.GetId()}, nil
	case "delete_provider":
		var msg panelpb.DeleteProviderResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return DeleteProviderResult{OK: msg.GetOk()}, nil
	case "set_default_provider":
		var msg panelpb.SetDefaultProviderResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return SetDefaultProviderResult{OK: msg.GetOk()}, nil
	case "test_provider":
		var msg panelpb.TestProviderResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return TestProviderResult{OK: msg.GetOk(), LatencyMS: msg.GetLatencyMs(), Error: msg.GetError()}, nil
	case "get_risk_policies":
		var msg panelpb.GetRiskPoliciesResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		policies := make([]RiskPolicy, 0, len(msg.GetPolicies()))
		for _, p := range msg.GetPolicies() {
			policies = append(policies, RiskPolicy{
				RiskLevel: p.GetRiskLevel(),
				Action:    p.GetAction(),
			})
		}
		return policies, nil
	case "set_risk_policy":
		var msg panelpb.SetRiskPolicyResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return SetRiskPolicyResult{OK: msg.GetOk()}, nil
	case "set_session_provider":
		var msg panelpb.SetSessionProviderResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return SetSessionProviderResult{OK: msg.GetOk()}, nil
	case "list_memories":
		var msg panelpb.ListMemoriesResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		memories := make([]MemoryEntry, 0, len(msg.GetMemories()))
		for _, m := range msg.GetMemories() {
			memories = append(memories, MemoryEntry{
				Key:       m.GetKey(),
				Tier:      pbMemoryTierToString(m.GetTier()),
				Content:   m.GetContent(),
				Source:    m.GetSource(),
				CreatedAt: m.GetCreatedAt(),
				SessionID: m.GetSessionId(),
			})
		}
		return memories, nil
	case "add_memory":
		var msg panelpb.AddMemoryResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return AddMemoryResult{OK: msg.GetOk(), Key: msg.GetKey()}, nil
	case "delete_memory":
		var msg panelpb.DeleteMemoryResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return DeleteMemoryResult{OK: msg.GetOk()}, nil
	case "clear_memories":
		var msg panelpb.ClearMemoriesResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return ClearMemoriesResult{OK: msg.GetOk(), Count: msg.GetCount()}, nil
	case "stop":
		var msg panelpb.StopResult
		if err := proto.Unmarshal(bin, &msg); err != nil {
			return nil, err
		}
		return StopResult{OK: msg.GetOk()}, nil
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

func intArg(args map[string]any, key string) int {
	v, ok := args[key]
	if !ok || v == nil {
		return 0
	}
	switch n := v.(type) {
	case int:
		return n
	case int32:
		return int(n)
	case int64:
		return int(n)
	case float64:
		return int(n)
	case float32:
		return int(n)
	default:
		return 0
	}
}

// StreamEvent 是 panel_server 推送到 Wails 前端的流式事件 (经 Wails EmitEvent 广播)。
type StreamEvent struct {
	StreamID string         `json:"stream_id"`
	Kind     string         `json:"kind"` // chunk | tool_event | final | error | approval_required | plan_generated | plan_step_update
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
		ev.Payload["arguments"] = pbJSONValueToAny(te.GetArguments())
		ev.Payload["result"] = pbJSONValueToAny(te.GetResult())
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
	if ap := stream.GetApprovalRequired(); ap != nil {
		ev.Kind = "approval_required"
		ev.Payload["req_id"] = ap.GetReqId()
		ev.Payload["session_id"] = ap.GetSessionId()
		ev.Payload["tool_call_id"] = ap.GetToolCallId()
		ev.Payload["tool_name"] = ap.GetToolName()
		ev.Payload["arguments_json"] = ap.GetArgumentsJson()
		ev.Payload["risk_level"] = ap.GetRiskLevel()
		ev.Payload["expire_ms"] = ap.GetExpireMs()
		return ev
	}
	if plan := stream.GetPlanGenerated(); plan != nil {
		ev.Kind = "plan_generated"
		steps := make([]any, 0, len(plan.GetSteps()))
		for _, s := range plan.GetSteps() {
			steps = append(steps, map[string]any{
				"index":       s.GetIndex(),
				"description": s.GetDescription(),
				"tool_hint":   s.GetToolHint(),
				"risk_level":  s.GetRiskLevel(),
			})
		}
		ev.Payload["goal"] = plan.GetGoal()
		ev.Payload["steps"] = steps
		ev.Payload["warnings"] = append([]string(nil), plan.GetWarnings()...)
		ev.Payload["suggestions"] = append([]string(nil), plan.GetSuggestions()...)
		return ev
	}
	if upd := stream.GetPlanStepUpdate(); upd != nil {
		ev.Kind = "plan_step_update"
		ev.Payload["step_index"] = upd.GetStepIndex()
		ev.Payload["status"] = pbPlanStatusToString(upd.GetStatus())
		ev.Payload["result_summary"] = upd.GetResultSummary()
		return ev
	}
	ev.Kind = "unknown"
	return ev
}

func pbToolCallsToSlice(toolCalls []*panelpb.ToolCall) []ToolCall {
	if len(toolCalls) == 0 {
		return nil
	}
	out := make([]ToolCall, 0, len(toolCalls))
	for _, tc := range toolCalls {
		out = append(out, pbToolCallToToolCall(tc))
	}
	return out
}

func pbToolCallToToolCall(tc *panelpb.ToolCall) ToolCall {
	f := tc.GetFunction()
	return ToolCall{
		ID:   tc.GetId(),
		Type: defaultString(tc.GetType(), "function"),
		Function: ToolFunction{
			Name:      f.GetName(),
			Arguments: pbJSONValueToAny(f.GetArguments()),
		},
	}
}

func pbJSONValueToAny(v *panelpb.JsonValue) any {
	if v == nil {
		return nil
	}
	switch kind := v.GetKind().(type) {
	case *panelpb.JsonValue_StringValue:
		return kind.StringValue
	case *panelpb.JsonValue_NumberValue:
		if math.Trunc(kind.NumberValue) == kind.NumberValue {
			return int64(kind.NumberValue)
		}
		return kind.NumberValue
	case *panelpb.JsonValue_BoolValue:
		return kind.BoolValue
	case *panelpb.JsonValue_ObjectValue:
		obj := map[string]any{}
		for _, field := range kind.ObjectValue.GetFields() {
			obj[field.GetKey()] = pbJSONValueToAny(field.GetValue())
		}
		return obj
	case *panelpb.JsonValue_ArrayValue:
		items := make([]any, 0, len(kind.ArrayValue.GetItems()))
		for _, item := range kind.ArrayValue.GetItems() {
			items = append(items, pbJSONValueToAny(item))
		}
		return items
	case *panelpb.JsonValue_NullValue:
		return nil
	default:
		return nil
	}
}

func defaultString(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}

func pbToolParametersToAny(v *panelpb.ToolParameters) any {
	if v == nil {
		return nil
	}
	props := map[string]any{}
	required := make([]any, 0, len(v.GetProperties()))
	for _, p := range v.GetProperties() {
		prop := map[string]any{}
		if typ := p.GetType(); typ != "" {
			prop["type"] = typ
		}
		if desc := p.GetDescription(); desc != "" {
			prop["description"] = desc
		}
		props[p.GetName()] = prop
		if p.GetRequired() {
			required = append(required, p.GetName())
		}
	}
	out := map[string]any{
		"type":       defaultString(v.GetType(), "object"),
		"properties": props,
	}
	if len(required) > 0 {
		out["required"] = required
	}
	return out
}

func decodeToolParametersPB(bin []byte) any {
	if len(bin) == 0 {
		return nil
	}
	var msg panelpb.ToolParameters
	if err := proto.Unmarshal(bin, &msg); err != nil {
		return nil
	}
	return pbToolParametersToAny(&msg)
}

func mapArg(args map[string]any, key string) map[string]any {
	v, ok := args[key]
	if !ok || v == nil {
		return map[string]any{}
	}
	switch m := v.(type) {
	case map[string]any:
		return m
	default:
		return map[string]any{}
	}
}

func pbProviderConfigFromMap(m map[string]any) *panelpb.ProviderConfig {
	if m == nil {
		return nil
	}
	models := []string{}
	if rawModels, ok := m["models"]; ok {
		if modelSlice, ok := rawModels.([]any); ok {
			for _, model := range modelSlice {
				models = append(models, fmt.Sprint(model))
			}
		}
	}
	return &panelpb.ProviderConfig{
		Id:        stringArg(m, "id"),
		Name:      stringArg(m, "name"),
		ApiBase:   stringArg(m, "api_base"),
		ApiKey:    stringArg(m, "api_key"),
		Models:    models,
		Enabled:   boolArg(m, "enabled"),
		IsDefault: boolArg(m, "is_default"),
	}
}

func pbMemoryTierFromString(s string) panelpb.MemoryTier {
	switch s {
	case "facts":
		return panelpb.MemoryTier_MEMORY_TIER_FACTS
	case "preferences":
		return panelpb.MemoryTier_MEMORY_TIER_PREFERENCES
	case "workspace":
		return panelpb.MemoryTier_MEMORY_TIER_WORKSPACE
	default:
		return panelpb.MemoryTier_MEMORY_TIER_UNSPECIFIED
	}
}

func pbMemoryTierToString(t panelpb.MemoryTier) string {
	switch t {
	case panelpb.MemoryTier_MEMORY_TIER_FACTS:
		return "facts"
	case panelpb.MemoryTier_MEMORY_TIER_PREFERENCES:
		return "preferences"
	case panelpb.MemoryTier_MEMORY_TIER_WORKSPACE:
		return "workspace"
	default:
		return "unspecified"
	}
}

func pbPlanStatusToString(s panelpb.PlanStepStatus) string {
	switch s {
	case panelpb.PlanStepStatus_PLAN_STEP_PENDING:
		return "pending"
	case panelpb.PlanStepStatus_PLAN_STEP_RUNNING:
		return "running"
	case panelpb.PlanStepStatus_PLAN_STEP_DONE:
		return "done"
	case panelpb.PlanStepStatus_PLAN_STEP_FAILED:
		return "failed"
	case panelpb.PlanStepStatus_PLAN_STEP_SKIPPED:
		return "skipped"
	default:
		return "pending"
	}
}
