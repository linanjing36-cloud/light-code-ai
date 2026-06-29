# Hermes Agent 产品需求文档 (PRD)

**版本**: v2.0  
**日期**: 2026-06-30  
**作者**: 产品经理视角  
**状态**: 基于当前代码现状的产品规划

---

## 1. 产品概述

### 1.1 产品定位

Hermes Agent 是一款**本地化、可扩展、安全可控的桌面 AI Agent 工作台**。采用 Erlang/OTP 强控编排 + Go/Eino 执行层 + Wails v3 桌面前端的三进程架构，面向开发者提供代码理解、工程操作、多模态处理等 AI 辅助能力。

核心差异化：
- **编排权在 Erlang**：ReAct 循环、上下文组装、审批治理、容错恢复全部由 Erlang/OTP 保证，LLM 不能自主发起未经审批的操作
- **能力平台化**：tool / plugin / mcp / skill 四类能力通过统一 Capability 模型注册、裁剪、审批
- **本地优先**：桌面端独立运行，API Key 本地存储，所有对话数据本地持久化
- **可观测**：执行轨迹、FSM 状态、Token 消耗、工具调用链全程可视化

### 1.2 目标用户

| 用户画像 | 核心场景 | 优先级 |
|---------|---------|--------|
| 软件开发者 | 代码理解、重构建议、多文件编辑、Git 操作、Issue 分析 | P0 |
| 技术团队 Lead | 代码审查、架构分析、仓库概览、跨文件影响分析 | P1 |
| 高级用户 | 多模态任务（图片理解、语音输入）、自定义 MCP 接入 | P2 |

### 1.3 当前完成度评估（2026-06-30）

| 模块 | 完成度 | 状态说明 |
|------|--------|---------|
| 三进程架构底座 | **95%** | Wails-Go-Erlang 通信链路、双通道防腐层、连接池、重连全部通过验收 |
| ReAct 编排核心 | **90%** | agent_fsm 四态流转、并行工具调度、循环上限、FSM 崩溃恢复已验收 |
| 上下文工程 | **85%** | History裁剪、分阶段Prompt、摘要记忆、RAG注入、三层记忆后端已完成 |
| 能力平台 | **80%** | 统一Capability模型、四类能力注册、selector/policy裁剪、MCP接入已验收 |
| 审批中心 | **75%** | 审批等待链路、前端审批中心UI、全局队列拉取已验收；需结合provider风险策略 |
| 计划校验链 | **50%** | Planner/Verifier/Critic后端已实现；前端计划面板、进度追踪未做 |
| 记忆治理 | **50%** | 三层记忆后端（facts/preferences/workspace）已实现；手动记忆工具、记忆管理UI未做 |
| Provider配置中心 | **40%** | provider_store后端、凭证注入、风险策略已实现；前端配置UI、Proto/Go RPC未做 |
| 多模态能力 | **10%** | GitHub节流已完成；ASR/OCR/文生图待开发 |
| 可观测性 | **70%** | Trace面板、FSM状态、Token统计已有；计划可视化、记忆面板、Provider面板未做 |
| 构建与交付 | **60%** | Windows编译/启动脚本完整；macOS签名公证、自动更新未做 |

**整体完成度约 65%**。核心对话链路和能力平台已可用，P2 阶段后端已落地但前端/协议层未闭环。

---

## 2. 用户故事与需求

### 2.1 P0：核心对话体验（已基本完成，需打磨）

**US-P0-01 新建会话与对话**
- 作为用户，我可以启动应用并新建会话，输入消息后 Agent 开始思考
- 系统实时展示 Agent 的思考过程（流式输出）和工具调用
- Agent 完成后给出最终答案，等待我的下一条输入
- **状态**：已通过验收（ACPT-P0-001~006）
- **待优化**：reasoning_content 推理过程展示、中断/取消按钮

**US-P0-02 会话管理**
- 作为用户，我可以在左侧边栏看到所有会话列表，切换不同会话
- 我可以删除不需要的会话（清除对话历史和相关记忆）
- **状态**：已实现，待优化会话标题自动生成

**US-P0-03 高风险操作审批**
- 作为用户，当 Agent 尝试执行高风险操作（如写文件、执行命令）时，我需要收到审批弹窗
- 我可以在独立的审批中心查看所有待审批请求，按会话过滤
- 批准后 Agent 继续执行，拒绝后 Agent 收到拒绝信号
- **状态**：已通过验收（ACPT-P2-004）
- **待优化**：审批理由备注、自动审批规则（基于信任度/能力类型）

### 2.2 P1：能力扩展与发现

**US-P1-01 能力目录浏览**
- 作为用户，我可以在能力市场面板浏览所有可用能力
- 我可以按类型（tool/plugin/mcp/skill）、来源、风险等级筛选能力
- 我可以搜索能力名称或描述
- 点击能力可查看详情（参数Schema、描述、标签）并手动调试执行
- **状态**：已实现（ACPT-P1-005~008）

**US-P1-02 代码仓库理解**
- 作为开发者，我可以让 Agent 分析代码仓库结构（repo_map）
- 我可以语义搜索代码（code_search）
- 我可以通过 codegraph 查看函数调用链（callers/callees/impact）
- 我可以让 Agent 生成 GitHub 仓库概览和 diff 摘要
- **状态**：已通过验收（ACPT-P1-003/004/009/013）

**US-P1-03 执行轨迹追踪**
- 作为用户，我可以看到当前轮次 Agent 调用了哪些工具
- 每个工具调用显示：工具名、参数、结果/错误、耗时
- 我可以在Trace面板展开查看详细参数和返回值
- **状态**：已实现（ACPT-P1-005）

### 2.3 P2：智能规划与记忆治理

**US-P2-01 执行计划可见**
- 作为用户，当 Agent 收到复杂任务时，我能看到它制定的执行计划
- 计划展示：目标、步骤列表、风险警告、假设条件
- 每步标注是否需要工具、风险等级、预期产出
- 执行过程中实时更新步骤状态（待执行/执行中/已完成/已跳过/失败）
- Agent 自我审视的警告和建议也应展示
- **状态**：后端已实现（planner_chain），前端面板未做
- **验收标准**：
  - 复杂任务（多步骤、长度>80字节）首轮自动生成计划
  - 计划注入system prompt指导后续执行
  - 前端计划面板渲染goal/steps/warnings
  - 步骤状态随tool_event实时更新
  - 简单任务不触发计划（避免overhead）

**US-P2-02 跨会话记忆**
- 作为用户，Agent 应该记住我的事实信息（名字、技术栈、项目信息）
- Agent 应该记住我的偏好（回答风格、语言、代码风格）
- Agent 应该记住工作区上下文（项目架构、技术选型）
- 我可以在记忆管理面板查看、编辑、删除这些记忆
- Agent 应在每次对话开始时自动加载相关记忆
- **状态**：后端三层记忆已实现（memory_tier），手动写入工具和前端UI未做
- **验收标准**：
  - 多轮对话后Agent能回忆起之前提到的事实和偏好
  - 记忆按facts/preferences/workspace分类存储
  - 记忆管理面板可查看/搜索/编辑/删除记忆条目
  - 新会话自动加载global层记忆
  - 记忆来源标注（自动抽取/手动添加）

**US-P2-03 Provider 配置管理**
- 作为用户，我可以在设置面板配置多个 LLM Provider
- 每个 Provider 可以配置：名称、API Base URL、API Key、支持的模型列表
- 我可以设置默认 Provider 和默认模型
- 我可以为不同模型配置路由规则（如GPT-4用于复杂任务、DeepSeek用于日常对话）
- API Key 在界面上掩码显示，存储在本地安全位置
- **状态**：后端provider_store已实现，前端配置UI和Proto/Go RPC未做
- **验收标准**：
  - 可添加/编辑/删除/启用/禁用Provider
  - API Key 保存后掩码显示（sk-1234****）
  - 模型路由规则配置并生效
  - 会话级Provider覆盖（当前会话临时切换模型）
  - 凭证注入链路正确（bridge_manager从provider_store解析）
  - 旧配置（api-key.json）自动迁移为env-default provider

**US-P2-04 风险策略配置**
- 作为用户，我可以配置不同风险等级的默认处理策略
- 风险等级：safe / review / dangerous
- 默认策略：safe直接执行、review需审批、dangerous默认拒绝
- 我可以自定义每个风险等级的动作（允许/审批/拒绝）
- **状态**：后端risk_policies表已实现默认策略seed，前端配置UI未做
- **验收标准**：
  - 设置面板可调整风险策略
  - 策略变更即时生效
  - dangerous级别工具默认被capability_selector裁剪

### 2.4 P3：多模态能力

**US-P3-01 语音输入（ASR）**
- 作为用户，我可以通过语音输入消息，系统自动转文字
- 支持中英文语音识别
- **状态**：待开发（P1-010）

**US-P3-02 图片理解（OCR/VLM）**
- 作为用户，我可以上传图片让 Agent 理解
- 支持截图粘贴、图片拖放
- Agent 可识别图片中的代码、文字、图表
- **状态**：待开发（P1-011）

**US-P3-03 文生图**
- 作为用户，我可以让 Agent 生成图片
- 生成过程异步进行，完成后在对话中展示
- **状态**：待开发（P1-012）

### 2.5 P4：可观测性与运维

**US-P4-01 执行控制**
- 作为用户，我可以取消正在执行的任务
- 我可以暂停长时间运行的任务，稍后恢复
- **状态**：待开发（P2-004增强项）

**US-P4-02 模型与Token统计**
- 作为用户，我可以看到每次对话的Token消耗（prompt/completion）
- 我可以看到按会话/按天/按月的Token使用统计
- **状态**：FinalAnswer已返回token数，统计面板未做

**US-P4-03 健康状态面板**
- 作为用户，我可以看到 Erlang Brain、Go 执行层、MCP 服务的连接状态
- 异常时显示明确的错误信息和恢复建议
- **状态**：基础连接状态已展示，详细诊断面板未做

---

## 3. 功能优先级矩阵

### 3.1 MoSCoW 优先级

| 优先级 | 功能 | 说明 |
|--------|------|------|
| **Must Have** | P2-001/002/003 前后端闭环 | 计划面板+记忆管理UI+Provider配置UI — 后端已就绪，补全Proto/RPC/前端 |
| **Must Have** | 记忆手动写入工具 | memory_fact/memory_preference/memory_workspace 三个工具暴露给LLM |
| **Should Have** | 会话标题自动生成 | 基于首条消息自动生成会话标题 |
| **Should Have** | 推理过程展示 | reasoning_content 折叠面板展示 |
| **Should Have** | 取消/停止执行 | 中断当前Agent执行 |
| **Should Have** | Token使用统计面板 | 按会话/时间维度统计Token消耗 |
| **Could Have** | ASR语音输入 | 麦克风按钮+语音转文字 |
| **Could Have** | 图片上传/粘贴 | 拖放/粘贴图片到对话 |
| **Could Have** | 审批自动规则 | 基于能力来源/信任度的自动审批 |
| **Won't Have (本期)** | 文生图 | 异步任务系统复杂度高，延后 |
| **Won't Have (本期)** | macOS签名公证 | 需要Apple开发者账号，延后 |
| **Won't Have (本期)** | 自动更新 | 桌面端自动更新框架，延后 |

### 3.2 依赖关系

```
P2-003 Provider配置UI ──依赖──▶ Proto扩展(list_providers/upsert_provider/...)
P2-001 计划面板 ──依赖──▶ Proto扩展(PlanSection注入PanelStream?或独立RPC)
P2-002 记忆管理UI ──依赖──▶ Proto扩展(list_memories/add_memory/delete_memory)
记忆手动工具 ──依赖──▶ panel_tools注册 → Eion-tools tool注册
取消执行 ──依赖──▶ agent_fsm cancel消息 → bridge_manager cancel in-flight
```

---

## 4. 非功能性需求

### 4.1 性能
- 首Token延迟（TTFT）：简单对话 < 2s（不含网络延迟）
- 计划生成：复杂任务计划生成 < 5s（同步阻塞thinking前）
- 记忆抽取：异步执行，不阻塞响应（已有10s debounce）
- UI 帧率：流式输出时滚动流畅 > 30fps

### 4.2 可靠性
- Erlang进程崩溃：监督树毫秒级重启，从快照恢复（已实现）
- Go执行层断连：bridge_manager自动重连+柔性降级（已实现）
- Mnesia持久化：60s周期快照，重启可恢复（已实现）
- API Key安全：存储本地Mnesia，掩码展示，不写入日志

### 4.3 安全
- 高风险操作必须审批（已有approval_store+capability_policy）
- API Key 不通过前端localStorage明文存储（当前存localStorage，需迁移到后端provider_store）
- 工具执行幂等（已有req_id幂等缓存）
- MCP stdio进程沙箱隔离（待实现：MCP进程权限降级）

### 4.4 兼容性
- Windows 10+ 主力支持
- macOS 12+ 编译支持（签名公证延后）
- Linux 命令行模式支持
- 旧版 api-key.json 配置自动升级为 provider_store env-default

---

## 5. 交互设计要点

### 5.1 计划面板
- 位置：对话区右侧/上方可折叠面板
- 展示内容：
  - 🎯 目标（goal）
  - 📋 步骤列表（编号 + 工具标签 + 风险标记 + 状态图标）
  - ⚠️ 风险警告（warnings）
  - 💡 自我批评（critique issues）
- 交互：
  - 计划生成时淡入展示
  - 步骤状态随 tool_event 实时更新（⏳待执行 → 🔄执行中 → ✅完成/❌失败/⏭️跳过）
  - 用户可折叠/展开计划面板
  - 用户可点击步骤查看预期产出和备注

### 5.2 记忆管理面板
- 入口：侧边栏设置按钮 → 记忆管理
- 展示内容：
  - 三个Tab：📌事实 / ❤️偏好 / 📂工作区
  - 每条记忆：内容、来源标签（自动/手动）、创建时间、会话ID
  - 全局记忆 vs 会话记忆区分标识
- 交互：
  - 搜索记忆内容
  - 手动添加记忆（选择分类+输入内容）
  - 删除单条记忆
  - 一键清除某分类所有记忆
  - 导出/导入记忆（JSON）

### 5.3 Provider配置面板
- 入口：侧边栏设置按钮 → 模型配置
- 展示内容：
  - Provider列表（名称、状态、模型数、默认标记）
  - 选中Provider的详细配置（API Base、API Key（掩码）、模型列表）
  - 模型路由表（模型名 → Provider映射）
  - 风险策略配置（safe/review/dangerous → allow/approve/deny）
- 交互：
  - 添加/编辑/删除Provider
  - 测试连接（验证API Key有效性）
  - 设置默认Provider
  - 配置模型路由
  - 调整风险策略

### 5.4 现有UI优化
- 会话标题：首条用户消息自动截取（已有，需优化截断和中文处理）
- 推理过程：reasoning_content以折叠区展示（如"思考过程..."）
- 停止按钮：在发送按钮旁边/替换为停止按钮（当Agent执行中）
- Token统计：在FinalAnswer元信息区展示prompt/completion tokens

---

## 6. 数据模型

### 6.1 Provider配置（已实现后端）
```erlang
%% provider_configs 表
#{
  id => binary(),           %% provider唯一标识
  name => binary(),         %% 显示名称
  api_base => binary(),     %% API Base URL
  api_key => binary(),      %% API Key（明文存储，API掩码输出）
  models => [binary()],     %% 支持的模型列表
  enabled => boolean(),     %% 是否启用
  is_default => boolean(),  %% 是否默认provider
  created_at => integer(),
  updated_at => integer()
}
```

### 6.2 三层记忆（已实现后端）
```erlang
%% tiered_memories 表
#{
  session_id => binary(),   %% <<"global">> 或具体会话ID
  tier => facts|preferences|workspace,
  key => binary(),          %% 归一化哈希（幂等）
  content => binary(),      %% 记忆内容
  source => auto|manual,    %% 自动抽取/手动添加
  created_at => integer(),
  updated_at => integer()
}
```

### 6.3 执行计划（已实现后端，前端需消费）
```json
{
  "goal": "分析代码库架构并生成文档",
  "steps": [
    {"id": 1, "action": "扫描项目结构", "tool": "repo_map", "risk": "safe", "expected": "目录树"},
    {"id": 2, "action": "检索核心模块", "tool": "code_search", "risk": "safe", "expected": "关键文件列表"}
  ],
  "warnings": ["大型仓库分析可能耗时较长"],
  "assumptions": ["用户在项目根目录"],
  "critique": {
    "issues": ["未考虑依赖分析"],
    "suggestions": ["补充依赖图分析"]
  }
}
```

---

## 7. 里程碑规划

### M1：P2前后端闭环（1-2周）
- Proto扩展：provider CRUD、memory CRUD、plan stream事件
- Go侧：panel_codec适配新消息类型、RPC路由
- 前端：Provider配置面板、记忆管理面板、计划面板
- LLM工具：memory_fact/memory_preference/memory_workspace注册
- 回归：make.ps1 test 全绿

### M2：体验打磨（1周）
- 推理过程展示
- 取消/停止执行
- 会话标题自动生成优化
- Token统计面板
- API Key从localStorage迁移到后端provider_store

### M3：多模态起步（1-2周）
- 图片上传/粘贴（OCR/VLM路径）
- ASR语音输入
- 必要的Eion-tools插件开发

### M4：交付就绪（持续）
- macOS构建脚本
- 全面回归测试
- 文档与示例

---

## 8. 成功指标

| 指标 | 目标值 | 度量方式 |
|------|--------|---------|
| 核心对话成功率 | > 95% | panel_full_e2e通过率 |
| 规划触发准确率 | > 80% | 人工评估：复杂任务是否有计划 |
| 记忆召回有效率 | > 70% | 人工评估：记忆是否被正确注入和使用 |
| 配置切换成功率 | 100% | Provider切换后LLM调用成功 |
| eunit测试通过率 | 100% | rebar3 eunit |
| E2E测试通过率 | 100% | make.ps1 test |
| 崩溃恢复率 | 100% | FSM崩溃后能从快照续跑 |

---

## 9. 开放问题

1. **API Key存储安全**：当前localStorage明文存储，是否需要OS级密钥环（如Windows Credential Manager / macOS Keychain）？
2. **计划展示侵入性**：计划面板是否默认展开，还是折叠为小徽章？
3. **记忆自动抽取频率**：当前每次final answer后触发，是否需要更智能的阈值控制？
4. **多Provider并发**：是否支持在同一会话中对不同类型请求使用不同Provider（如LLM用DeepSeek、Embedding用OpenAI）？
5. **MCP市场**：是否需要做MCP Server的发现/安装/管理市场？
