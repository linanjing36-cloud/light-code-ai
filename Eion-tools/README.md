# Eion-tools

Eion-tools 是 [Hermes Agent](https://github.com/light-code-ai) 系统的"执行肌肉"：把字节跳动 [Eino](https://github.com/cloudwego/eino) 框架包装成一个**无状态执行 SDK**，供 Erlang 侧的 Agent-brains 调用。

## 核心约束

- **只做执行，不做编排。** Eion-tools 仅使用 Eino 的 `model.ChatModel` 与 `tools.Tool` 两个接口；**严禁**使用 `agent.NewAgent`、`Chain`、`Graph` —— 否则会把编排控制权泄漏到 Go 侧。
- **Go 侧无状态、无内部循环。** "问什么答什么"：一次原子请求 → 一次响应。多轮对话、工具调用循环、状态机等编排逻辑全部由 Erlang 侧（Agent-brains）掌控。
- **Provider 配置由请求携带。** `model` / `api_base` / `api_key` 都在每次 `LLMInferRequest` 中传入，Go 侧不缓存、不持有任何 provider 长连接状态。
- **唯一的幂等例外。** dispatcher 维护一个 `sync.Map`，按 `ToolExecRequest.req_id` 缓存工具执行结果，避免 Erlang 重试导致副作用工具被重复执行。

## Protobuf 契约

Erlang ↔ Go 之间的唯一 IPC 契约定义在 [`proto/hermes.proto`](proto/hermes.proto)：

- `AgentRequest` / `AgentResponse` —— 顶层包装，使用 `oneof` 区分 LLM 推理 vs 工具执行。
- `LLMInferRequest` / `LLMInferResponse` —— 单次 LLM 推理。
- `ToolExecRequest` / `ToolExecResponse` —— 单次工具执行。
- `Message` / `ToolCall` / `ToolDesc` —— 共享的消息与工具类型。

## 目录结构

```
Eion-tools/
├── proto/hermes.proto              # Protobuf 契约（与 Erlang 共享）
├── internal/
│   ├── dispatcher/dispatcher.go    # 路由 + Panic_Guard + 幂等缓存
│   ├── model/wrapper.go            # Eino ChatModel 薄适配器
│   └── tool/wrapper.go             # Eino Tool 注册表 + 示例工具 get_weather
├── cmd/server/main.go              # 入口：stdin/stdout 二进制帧循环（Erlang 端口占位）
└── go.mod
```

## 如何被 Agent-brains（Erlang）调用

1. Erlang 端通过 Erlang port / IPC 向 Go 进程写入一帧：`[4 字节大端长度][protobuf AgentRequest]`。
2. Go 进程 `cmd/server` 读取该帧，解码为 `AgentRequest`，交给 `dispatcher.Dispatch`。
3. dispatcher 根据 `oneof` 分支路由到 `model.Wrapper.Infer` 或对应 `tool.Tool`。
4. 任何 panic 由 `Panic_Guard` 捕获并转成错误响应，避免端口卡死。
5. Go 进程写回同样格式的 `AgentResponse` 帧：`[4 字节大端长度][protobuf AgentResponse]`。

> 当前 `cmd/server/main.go` 的 stdin/stdout 帧循环是占位实现，后续将被真实的 Erlang port driver 替换。

## 状态

骨架阶段。Eino 依赖与 protobuf 生成代码尚未接入 `go.mod`，关键逻辑处均留有 `TODO` 标记。
