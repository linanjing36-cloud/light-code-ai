# Hermes — Wails 面板 (Wails-v3)

智能体面板。基于 Wails v2 (Go + Web) 构建。

## 架构定位

```
Hermes 面板 (Wails/Go)  ──spawn──▶  Erlang ERTS (Agent-brains)
                                          │
                                Protobuf  │ IPC
                                          ▼
                                    Eion-tools (Go/Eino)  ← 无状态执行
```

**关键约束**: Wails 不直接嵌套 / 引入 Eion-tools。所有 LLM 推理与工具调用
都由 Erlang 侧的 `Agent_FSM` 编排后,经 `Bridge_Manager` 发往 Eion-tools。
Wails 侧仅做 UI 渲染与桥接,是"哑终端"。

## 目录

- `main.go` — Wails 入口,启动 Erlang 大脑子进程 + 前端窗口
- `app.go` — 暴露给前端 (React) 的 Go 方法,转发到 Erlang
- `internal/brain/` — Wails↔Erlang 桥接层 (spawn ERTS + ErlPort 通信)
- `prototype/` — 高保真 UI 原型 (HTML/CSS/JS),作为前端设计基准
- `frontend/` — React 实现 (将基于 prototype/ 迁移)

## UI 设计

原型见 `prototype/index.html`。设计方向 **"Atelier Terminal"**:
暖色深底 + 藏红/琥珀强调色 (致敬 Hermes 权杖),编辑字体 × 终端美学。

参考 Zcode / Codex 的布局模式 (任务列表+时间线、计划清单、内联工具卡片、
内联审批),但视觉语言独立: 非冷调绿/黑、非蓝色,采用暖色系。

## 开发

```bash
# 1. 先编译 Agent-brains (产出 beam)
cd ../Agent-brains && rebar3 compile

# 2. 启动 Wails 面板
cd ../Wails-v3 && wails dev
```
