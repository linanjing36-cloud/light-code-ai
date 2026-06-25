# Agent-brains

Agent-brains 是 **Hermes Agent 系统** 的 Erlang/OTP 编排大脑 —— 唯一的控制中心。

## 角色分工

- **Erlang（Agent-brains）**：拥有所有编排逻辑 —— ReAct 循环、上下文组装、并行工具派发、故障恢复、记忆。
- **Go（Eion-tools）**：无状态执行 SDK。接收一次原子请求（`LLMInferRequest` 或 `ToolExecRequest`），返回一次响应即结束。Go 侧不缓存、不重试、不内部循环。
- **Protobuf**：Erlang ↔ Go 之间的唯一 IPC 契约（`proto/hermes.proto`）。业务逻辑只触碰 Erlang Map，由 `pb_codec` 模块做 Map ↔ Protobuf 转换（防腐层）。

## ReAct 状态机

核心由 `gen_statem` 实现，四个状态：

| 状态 | 职责 |
|------|------|
| `idle` | 等待会话启动；或最终答案就绪后驻留 |
| `thinking` | 组装上下文 → 发 `LLMInferRequest` → 等响应。有 `tool_calls` → `acting`；无 → `idle`（最终答案） |
| `acting` | 解析 `tool_calls`，**并行**派发 `ToolExecRequest`，收齐结果后进入 `observing` |
| `observing` | 将结果作为 observation 追加进历史，循环计数 +1。未超上限 → 回 `thinking`；超限 → 强制结束 |

- **循环上限**：最多 10 次迭代，防止 LLM 死循环。
- **崩溃恢复**：每次状态迁移前将 FSM 快照写入 ETS（`state_store`）。

## 模块

| 模块 | 职责 |
|------|------|
| `hermes_brains_app` | OTP 应用入口 |
| `hermes_brains_sup` | 顶层监督者（`rest_for_one`）：`state_store` + `agent_sup` |
| `agent_sup` | `simple_one_for_one` 监督者：每个 Agent 会话 = 一个 FSM 进程 |
| `agent_fsm` | **核心**：`gen_statem` ReAct 循环 |
| `context_assembler` | 纯函数式上下文组装器 |
| `bridge_manager` | Go 连接管理、超时、`nodedown` 通知 |
| `pb_codec` | Protobuf 防腐层（Map ↔ `hermes_pb`） |
| `state_store` | ETS 持有者：FSM 快照 + 短期记忆 |

## 构建

```bash
rebar3 compile   # 需先拉取 deps 并放置 proto/hermes.proto
rebar3 shell
```
