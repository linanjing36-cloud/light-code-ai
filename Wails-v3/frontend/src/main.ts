// Hermes Agent Workbench — 前端入口
//
// 与 Go 侧 HermesService (Wails v3 binding) 交互:
//   HermesService.StartSession(prompt)  → 派发 agent_fsm
//   HermesService.Send(sid, msg)        → 触发 ReAct (异步, 立即返回 stream_id)
//   HermesService.BrainStatus(sid)      → 读 FSM 状态 (idle/thinking/acting)
//   HermesService.GetHistory(sid)       → 拉取 state_store 短期记忆
//   RouterBinding.CallPanel(...)        → 直连 panel_server 的能力目录与调试入口
//   HermesService.StopBrain()            → 优雅停止 Erlang 大脑
//
// 流式 chunk/final 由 panel:stream 事件驱动; 终态后 get_history 同步对话区。
// BrainStatus 轮询仅在「有待处理任务」时启动 (发送中 / 流式中 / thinking|acting)。

import { HermesService } from "../bindings/hermes";
import { SessionStartRequest } from "../bindings/hermes/models.js";
import * as RouterBinding from "../bindings/hermes/internal/router/router.js";
import { Events } from "@wailsio/runtime";

const CONFIG_STORAGE_KEY = "hermes_llm_config";

interface LLMConfig {
    model: string;
    apiBase: string;
    apiKey: string;
    systemPrompt: string;
}

const DEFAULT_CONFIG: LLMConfig = {
    model: "deepseek-v4-pro",
    apiBase: "https://api.deepseek.com",
    apiKey: "",
    systemPrompt: "",
};

const STATUS_POLL_INTERVAL_MS = 2500;

// ---- 类型 ----
type BrainState = "idle" | "thinking" | "acting" | "waiting_approval" | "unknown" | "not_found" | "error";

interface ApprovalRequest {
    req_id: string;
    session_id: string;
    tool_call_id: string;
    tool_name: string;
    arguments_json?: string;
    risk_level: string;
    expire_ms: number;
    createdAt: number;
}

interface ApprovalCenterEntry extends ApprovalRequest {
    session_title: string;
    session_model: string;
    is_current: boolean;
}

interface Session {
    id: string;
    title: string;
    model: string;
    createdAt: number;
    lastState: BrainState;
    msgCount: number;
    toolCalls: number;
    lastHistoryLen: number;
    history: HistoryEntry[];
    toolEvents: ToolEvent[]; // EXEC-P1-005: 执行轨迹 (开始/结束/失败)
    pendingApprovals: ApprovalRequest[]; // EXEC-P0-005: 等待用户审批的高风险能力
    currentPlan?: ExecutionPlan; // EXEC-P2-001: 当前执行计划
}

// EXEC-P1-005: 工具执行轨迹条目, 由后端 panel:stream tool_event 帧驱动。
// 同一 tool_call_id 先收到 finished=false (开始), 后收到 finished=true (结束/失败)。
interface ToolEvent {
    tool_call_id: string;
    name: string;            // 工具名 (开始事件携带)
    arguments_json?: string; // 工具入参 (开始事件携带, JSON 字符串)
    result_json?: string;    // 工具结果 (结束事件携带, JSON 字符串)
    error?: string;          // 失败原因 (结束事件携带, 非空表示失败)
    finished: boolean;       // true=已结束 (有 result 或 error), false=已开始
    startedAt: number;       // 开始事件时间戳 (ms)
    finishedAt?: number;     // 结束事件时间戳 (ms)
}

// ---- 状态 ----
let currentSessionId: string | null = null;
const sessions = new Map<string, Session>();
let brainConnected = false;
let statusTimer: number | null = null;
let isSending = false;
const sessionStreamIds = new Map<string, string>();
const sessionHistoryDirty = new Set<string>();
let backendPendingApprovals: ApprovalRequest[] = [];
let capabilityCatalog: CapabilityView[] = [];
let streamingMsgEl: HTMLElement | null = null;
let streamingMsgText: Text | null = null;
let streamingText = "";
let streamingScrollRaf = 0;

interface HistoryEntry {
    role: string;
    content: string;
    tool_calls?: ToolCall[];
    tool_call_id?: string;
}

interface ToolCall {
    id: string;
    type?: string;
    function?: {
        name?: string;
        arguments?: unknown;
    };
}

interface PanelStreamEvent {
    stream_id: string;
    kind: "chunk" | "tool_event" | "final" | "error" | "approval_required" | "plan_generated" | "plan_step_update" | "unknown";
    payload: Record<string, unknown>;
}

interface PlanStep {
    index: number;
    description: string;
    tool_hint?: string;
    risk_level: string;
    expected?: string;
    note?: string;
    status?: "pending" | "running" | "done" | "failed" | "skipped";
    result_summary?: string;
}

interface ExecutionPlan {
    goal: string;
    steps: PlanStep[];
    warnings: string[];
    suggestions: string[];
}

interface CapabilityView {
    name: string;
    description: string;
    kind: string;
    source: string;
    streaming: boolean;
    risk_level: string;
    cost_hint: string;
    tags?: string[];
    input_schema?: unknown;
}

interface DebugCapabilityResult {
    capability_name?: string;
    result_json?: string;
    error?: string;
}

function setupStreamListener(): void {
    Events.On("panel:stream", (ev) => {
        handlePanelStream(ev.data);
    });
}
setupStreamListener();

function handlePanelStream(ev: PanelStreamEvent): void {
    const targetSessionId = ev ? findSessionIdByStreamId(ev.stream_id) : null;
    const activeCurrentStreamId = getStreamIdForSession(currentSessionId);
    if (!ev || !targetSessionId) {
        return;
    }
    if (targetSessionId !== currentSessionId) {
        if (ev.kind === "tool_event") {
            sessionHistoryDirty.add(targetSessionId);
            applySessionState(targetSessionId, "acting", { updateCurrentUI: false });
        }
        if (ev.kind === "approval_required") {
            handleApprovalRequired(targetSessionId, ev.payload, false);
        }
        if (ev.kind === "plan_generated") {
            handlePlanGenerated(targetSessionId, ev.payload, false);
        }
        if (ev.kind === "final" || ev.kind === "error") {
            const sess = sessions.get(targetSessionId);
            if (sess) {
                sess.pendingApprovals = [];
            }
            renderApprovalCenter();
            void refreshPendingApprovalsFromBrain();
            if (ev.kind === "final") {
                void finalizeSessionUI(targetSessionId, String(ev.payload.content ?? ""));
            } else {
                clearStreamState(targetSessionId);
                applySessionState(targetSessionId, "error", { updateCurrentUI: false });
                sessionHistoryDirty.add(targetSessionId);
            }
        }
        return;
    }
    if (!activeCurrentStreamId || ev.stream_id !== activeCurrentStreamId) {
        return;
    }
    switch (ev.kind) {
        case "chunk": {
            const part = String(ev.payload.content ?? "");
            if (part) {
                streamingText += part;
                ensureStreamingMsg();
                if (streamingMsgText) {
                    streamingMsgText.appendData(part);
                    scheduleStreamingScroll();
                }
            }
            break;
        }
        case "final": {
            void finalizeSessionUI(targetSessionId, String(ev.payload.content ?? ""));
            break;
        }
        case "error": {
            removeThinking();
            appendAgentMsg(`<p style="color:var(--danger)">${escapeHtml(String(ev.payload.message ?? "stream error"))}</p>`);
            clearStreamState(targetSessionId);
            applySessionState(targetSessionId, "error");
            syncStatusPolling();
            break;
        }
        case "tool_event": {
            const sess = targetSessionId ? sessions.get(targetSessionId) : undefined;
            if (sess) {
                sessionHistoryDirty.add(targetSessionId);
                applySessionState(targetSessionId, "acting");
                sess.toolCalls += 1;
                handleToolEvent(sess, ev.payload);
                if (targetSessionId === currentSessionId) {
                    updateCanvasMeta(sess);
                    renderTracePanel(sess);
                }
            }
            break;
        }
        case "approval_required": {
            handleApprovalRequired(targetSessionId, ev.payload, true);
            break;
        }
        case "plan_generated": {
            handlePlanGenerated(targetSessionId, ev.payload, true);
            break;
        }
        case "plan_step_update": {
            handlePlanStepUpdate(targetSessionId, ev.payload);
            break;
        }
    }
}

function ensureStreamingMsg(): void {
    removeThinking();
    if (streamingMsgEl) return;
    removeEmptyState();
    streamingMsgEl = document.createElement("div");
    streamingMsgEl.className = "msg msg-agent streaming-live";
    streamingMsgEl.innerHTML = `
        <div class="msg-role">
            <div class="agent-avatar">☿</div>
            <span>HERMES</span>
        </div>
        <div class="msg-body"><p></p></div>
    `;
    const p = streamingMsgEl.querySelector(".msg-body p");
    streamingMsgText = document.createTextNode(streamingText);
    p?.appendChild(streamingMsgText);
    conv.appendChild(streamingMsgEl);
}

function getStreamIdForSession(sessionId: string | null | undefined): string | null {
    if (!sessionId) return null;
    return sessionStreamIds.get(sessionId) ?? null;
}

function findSessionIdByStreamId(streamId: string): string | null {
    for (const [sessionId, activeStreamId] of sessionStreamIds.entries()) {
        if (activeStreamId === streamId) return sessionId;
    }
    return null;
}

function clearStreamState(sessionId: string | null | undefined, preserveStreamingEl = false): void {
    if (!sessionId) return;
    const preservedEl = streamingMsgEl;
    const preservedText = streamingMsgText;
    sessionStreamIds.delete(sessionId);
    streamingText = "";
    if (!preserveStreamingEl && streamingScrollRaf) {
        window.cancelAnimationFrame(streamingScrollRaf);
        streamingScrollRaf = 0;
    }
    streamingMsgEl = preserveStreamingEl ? preservedEl : null;
    streamingMsgText = preserveStreamingEl ? preservedText : null;
    updateSessionInList(sessionId);
}

function scheduleStreamingScroll(): void {
    if (streamingScrollRaf) return;
    streamingScrollRaf = window.requestAnimationFrame(() => {
        streamingScrollRaf = 0;
        scrollConvToBottom();
    });
}

function applySessionState(sessionId: string | null | undefined, state: BrainState, extra?: { historyLen?: number; updateCurrentUI?: boolean }): void {
    if (!sessionId) return;
    const sess = sessions.get(sessionId);
    if (!sess) return;
    sess.lastState = state;
    if (typeof extra?.historyLen === "number") {
        sess.lastHistoryLen = extra.historyLen;
    }
    updateSessionInList(sessionId);
    if (extra?.updateCurrentUI !== false && sessionId === currentSessionId) {
        ctxFsmState.textContent = state;
        ctxFsmState.className = "state-badge " + stateClass(state);
        if (typeof extra?.historyLen === "number") {
            ctxHistory.textContent = String(extra.historyLen);
        }
    }
}

function cloneHistoryEntry(entry: HistoryEntry): HistoryEntry {
    return {
        role: entry.role,
        content: entry.content,
        tool_calls: entry.tool_calls?.map((toolCall) => ({
            id: toolCall.id,
            type: toolCall.type,
            function: toolCall.function
                ? {
                      name: toolCall.function.name,
                      arguments: toolCall.function.arguments,
                  }
                : undefined,
        })),
        tool_call_id: entry.tool_call_id,
    };
}

function cacheHistoryEntries(sess: Session, entries: HistoryEntry[]): void {
    sess.history = entries.map(cloneHistoryEntry);
}

function appendCachedHistoryEntry(sess: Session, entry: HistoryEntry): void {
    sess.history.push(cloneHistoryEntry(entry));
}

async function finalizeSessionUI(sessionId: string, finalContent: string): Promise<void> {
    const sess = sessions.get(sessionId);
    const needsHistoryRefresh = sessionHistoryDirty.has(sessionId) || !finalContent;
    if (sess) {
        sess.pendingApprovals = [];
        if (!needsHistoryRefresh) {
            appendCachedHistoryEntry(sess, { role: "assistant", content: finalContent });
        }
        applySessionState(sessionId, "idle", {
            historyLen: needsHistoryRefresh ? sess.lastHistoryLen + 1 : sess.history.length,
        });
        renderApprovalCenter();
        void refreshPendingApprovalsFromBrain();
    }

    if (sessionId !== currentSessionId) {
        clearStreamState(sessionId);
        if (needsHistoryRefresh) {
            sessionHistoryDirty.add(sessionId);
        } else {
            sessionHistoryDirty.delete(sessionId);
        }
        return;
    }

    if (finalContent) {
        streamingText = finalContent;
        ensureStreamingMsg();
        if (streamingMsgText) {
            streamingMsgText.data = finalContent;
        }
        scheduleStreamingScroll();
    }
    removeThinking();
    clearStreamState(sessionId, true);

    if (needsHistoryRefresh) {
        sessionHistoryDirty.delete(sessionId);
        await refreshHistoryFromBrain(sess);
    }
    syncStatusPolling();
}

// ---- DOM ----
const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const conv = $("conv")!;
const prompt = $("prompt") as HTMLTextAreaElement;
const btnSend = $("btn-send") as HTMLButtonElement;
const btnNewSession = $("btn-new-session") as HTMLButtonElement;
const btnSaveConfig = $("btn-save-config") as HTMLButtonElement;
const cfgModel = $("cfg-model") as HTMLSelectElement;
const cfgApiBase = $("cfg-api-base") as HTMLInputElement;
const cfgApiKey = $("cfg-api-key") as HTMLInputElement;
const cfgSystemPrompt = $("cfg-system-prompt") as HTMLTextAreaElement;
const modelBadgeText = $("model-badge-text")!;
const ctxTools = $("ctx-tools")!;
const capabilitySearch = $("capability-search") as HTMLInputElement;
const capabilityRiskFilter = $("capability-risk-filter") as HTMLSelectElement;
const capabilitySourceFilter = $("capability-source-filter") as HTMLSelectElement;
const capabilityKindFilter = $("capability-kind-filter") as HTMLSelectElement;
const capabilityMarketMeta = $("capability-market-meta")!;
const capabilityMarketDetail = $("capability-market-detail")!;
const capabilitySelect = $("capability-select") as HTMLSelectElement;
const capabilityArgs = $("capability-args") as HTMLTextAreaElement;
const capabilityRun = $("capability-run") as HTMLButtonElement;
const capabilityResult = $("capability-result") as HTMLElement;
const btnStop = $("btn-stop") as HTMLButtonElement;
const btnCancel = $("btn-cancel") as HTMLButtonElement;
const btnShutdown = $("btn-shutdown") as HTMLButtonElement;
const btnClear = $("btn-clear") as HTMLButtonElement;
const sessionList = $("session-list")!;
const sessionCount = document.getElementById("session-count");
const canvasTitle = $("canvas-title")!;
const canvasMeta = $("canvas-meta")!;
const brainDot = $("brain-dot")!;
const brainStateText = $("brain-state-text")!;
const ctxStatus = $("ctx-status")!;
const ctxFsmState = $("ctx-fsm-state")!;
const ctxLoop = $("ctx-loop")!;
const ctxHistory = $("ctx-history")!;
const ctxConn = $("ctx-conn")!;
const approvalCount = $("approval-count")!;
const approvalScope = $("approval-scope") as HTMLSelectElement;
const approvalCenter = $("approval-center")!;
const btnRefreshProviders = $("btn-refresh-providers") as HTMLButtonElement;
const providersList = $("providers-list")!;
const btnRefreshMemories = $("btn-refresh-memories") as HTMLButtonElement;
const memoryTierFilter = $("memory-tier-filter") as HTMLSelectElement;
const memoryAddTier = $("memory-add-tier") as HTMLSelectElement;
const memoryAddContent = $("memory-add-content") as HTMLInputElement;
const btnAddMemory = $("btn-add-memory") as HTMLButtonElement;
const memoriesList = $("memories-list")!;

// ============================================================
// 启动: Bridge.ServiceStartup 已由 Wails 自动调用 (连接 panel_server)
// Agent-brains 需先启动；embedded Eion 由宿主 hermes 进程内启动
// 这里轮询探活, 等连接就绪后启用 UI
// ============================================================
console.log("[hermes] workbench starting");
loadConfigToUI();
setTimeout(checkBrainReady, 500);

function loadConfig(): LLMConfig {
    try {
        const raw = localStorage.getItem(CONFIG_STORAGE_KEY);
        if (!raw) return { ...DEFAULT_CONFIG };
        return { ...DEFAULT_CONFIG, ...JSON.parse(raw) };
    } catch {
        return { ...DEFAULT_CONFIG };
    }
}

function saveConfig(cfg: LLMConfig): void {
    localStorage.setItem(CONFIG_STORAGE_KEY, JSON.stringify(cfg));
    updateModelBadge(cfg.model);
}

function loadConfigToUI(): void {
    const cfg = loadConfig();
    cfgModel.value = cfg.model;
    cfgApiBase.value = cfg.apiBase;
    cfgApiKey.value = cfg.apiKey;
    cfgSystemPrompt.value = cfg.systemPrompt;
    updateModelBadge(cfg.model);
}

function getConfigFromUI(): LLMConfig {
    return {
        model: cfgModel.value || DEFAULT_CONFIG.model,
        apiBase: cfgApiBase.value.trim(),
        apiKey: cfgApiKey.value.trim(),
        systemPrompt: cfgSystemPrompt.value.trim(),
    };
}

function updateModelBadge(model: string): void {
    modelBadgeText.textContent = model || DEFAULT_CONFIG.model;
}

btnSaveConfig.addEventListener("click", () => {
    const cfg = getConfigFromUI();
    saveConfig(cfg);
    toast("LLM 配置已保存");
});

approvalScope.addEventListener("change", () => {
    renderApprovalCenter();
});

capabilitySelect.addEventListener("change", () => {
    applyCapabilityPreset(capabilitySelect.value);
    renderCapabilityDetails(selectedCapability());
});

capabilitySearch.addEventListener("input", () => {
    renderCapabilityMarketplace();
});

capabilityRiskFilter.addEventListener("change", () => {
    renderCapabilityMarketplace();
});

capabilitySourceFilter.addEventListener("change", () => {
    renderCapabilityMarketplace();
});

capabilityKindFilter.addEventListener("change", () => {
    renderCapabilityMarketplace();
});

capabilityRun.addEventListener("click", async () => {
    const name = capabilitySelect.value;
    if (!name) {
        toast("请先选择能力");
        return;
    }
    let argumentsJSON = capabilityArgs.value.trim() || "{}";
    try {
        JSON.parse(argumentsJSON);
    } catch (e) {
        toast("能力参数 JSON 非法: " + e);
        return;
    }
    capabilityRun.disabled = true;
    capabilityResult.textContent = "执行中...";
    try {
        const out = (await RouterBinding.CallPanel("debug_capability", {
            capability_name: name,
            arguments_json: argumentsJSON,
            timeout_ms: 12000,
        })) as DebugCapabilityResult;
        if (out?.error) {
            capabilityResult.textContent = `ERROR\n${out.error}`;
        } else {
            capabilityResult.textContent = out?.result_json || "{}";
        }
    } catch (e) {
        capabilityResult.textContent = "ERROR\n" + String(e);
    } finally {
        capabilityRun.disabled = false;
    }
});

function normalizeCapability(raw: Record<string, unknown>): CapabilityView {
    return {
        name: String(raw.name || ""),
        description: String(raw.description || ""),
        kind: String(raw.kind || "tool"),
        source: String(raw.source || "builtin"),
        streaming: Boolean(raw.streaming),
        risk_level: String(raw.risk_level || "safe"),
        cost_hint: String(raw.cost_hint || "low"),
        tags: Array.isArray(raw.tags) ? raw.tags.map((tag) => String(tag)) : [],
        input_schema: raw.input_schema,
    };
}

function renderCapabilities(caps: CapabilityView[]): void {
    capabilityCatalog = caps;
    renderCapabilityFilterOptions();
    renderCapabilityMarketplace();
}

function filteredCapabilities(): CapabilityView[] {
    const q = capabilitySearch.value.trim().toLowerCase();
    const risk = capabilityRiskFilter.value;
    const source = capabilitySourceFilter.value;
    const kind = capabilityKindFilter.value;
    return capabilityCatalog.filter((cap) => {
        if (risk !== "all" && cap.risk_level !== risk) {
            return false;
        }
        if (source !== "all" && cap.source !== source) {
            return false;
        }
        if (kind !== "all" && cap.kind !== kind) {
            return false;
        }
        if (!q) {
            return true;
        }
        const haystack = [
            cap.name,
            cap.description,
            cap.kind,
            cap.source,
            cap.risk_level,
            cap.cost_hint,
            ...(cap.tags ?? []),
        ]
            .join(" ")
            .toLowerCase();
        return haystack.includes(q);
    });
}

function renderCapabilityFilterOptions(): void {
    const previousSource = capabilitySourceFilter.value || "all";
    const previousKind = capabilityKindFilter.value || "all";
    const sources = [...new Set(capabilityCatalog.map((cap) => cap.source).filter(Boolean))].sort();
    const kinds = [...new Set(capabilityCatalog.map((cap) => cap.kind).filter(Boolean))].sort();
    capabilitySourceFilter.innerHTML = [
        `<option value="all">全部来源</option>`,
        ...sources.map((source) => `<option value="${escapeHtml(source)}">${escapeHtml(source)}</option>`),
    ].join("");
    capabilityKindFilter.innerHTML = [
        `<option value="all">全部类型</option>`,
        ...kinds.map((kind) => `<option value="${escapeHtml(kind)}">${escapeHtml(kind)}</option>`),
    ].join("");
    capabilitySourceFilter.value = sources.includes(previousSource) ? previousSource : "all";
    capabilityKindFilter.value = kinds.includes(previousKind) ? previousKind : "all";
}

function capabilityByName(name: string | null | undefined): CapabilityView | undefined {
    if (!name) return undefined;
    return capabilityCatalog.find((cap) => cap.name === name);
}

function selectedCapability(): CapabilityView | undefined {
    return capabilityByName(capabilitySelect.value);
}

function renderCapabilityDetails(cap?: CapabilityView): void {
    if (!cap) {
        capabilityMarketDetail.innerHTML = `<div class="cap-market-detail-empty">选择一个能力查看详情</div>`;
        return;
    }
    const tags = cap.tags?.length
        ? cap.tags.map((tag) => `<span class="cap-tag">${escapeHtml(tag)}</span>`).join("")
        : `<span class="cap-tag muted">无标签</span>`;
    const schema = cap.input_schema ? truncate(JSON.stringify(cap.input_schema, null, 2), 480) : "";
    capabilityMarketDetail.innerHTML = `
        <div class="cap-market-detail-card">
            <div class="cap-market-detail-head">
                <div>
                    <div class="cap-market-detail-name">${escapeHtml(cap.name)}</div>
                    <div class="cap-market-detail-desc">${escapeHtml(cap.description || "暂无描述")}</div>
                </div>
                <div class="cap-market-risk">${escapeHtml(cap.risk_level)}</div>
            </div>
            <div class="cap-market-detail-grid">
                <div class="cap-market-stat"><span>来源</span><b>${escapeHtml(cap.source)}</b></div>
                <div class="cap-market-stat"><span>类型</span><b>${escapeHtml(cap.kind)}</b></div>
                <div class="cap-market-stat"><span>流式</span><b>${escapeHtml(cap.streaming ? "stream" : "non-stream")}</b></div>
                <div class="cap-market-stat"><span>成本</span><b>${escapeHtml(cap.cost_hint || "unknown")}</b></div>
            </div>
            <div class="cap-market-tags">${tags}</div>
            ${schema ? `<pre class="cap-market-schema">${escapeHtml(schema)}</pre>` : ""}
        </div>
    `;
}

function renderCapabilityMarketplace(): void {
    const caps = filteredCapabilities();
    const meta: string[] = [`${caps.length} / ${capabilityCatalog.length}`];
    if (capabilitySourceFilter.value !== "all") meta.push(`source:${capabilitySourceFilter.value}`);
    if (capabilityKindFilter.value !== "all") meta.push(`kind:${capabilityKindFilter.value}`);
    if (capabilityRiskFilter.value !== "all") meta.push(`risk:${capabilityRiskFilter.value}`);
    if (capabilitySearch.value.trim()) meta.push(`q:${capabilitySearch.value.trim()}`);
    capabilityMarketMeta.textContent = meta.join(" · ");
    if (!capabilityCatalog.length) {
        ctxTools.innerHTML = `<div class="tool-mini"><span class="dot off"></span>无可用能力</div>`;
        capabilityMarketMeta.textContent = "0 / 0";
        capabilityMarketDetail.innerHTML = `<div class="cap-market-detail-empty">暂无能力详情</div>`;
        capabilitySelect.innerHTML = `<option value="">暂无能力</option>`;
        capabilityArgs.value = "{}";
        capabilityResult.textContent = "";
        capabilityRun.disabled = true;
        return;
    }
    if (!caps.length) {
        ctxTools.innerHTML = `<div class="tool-mini"><span class="dot off"></span>无匹配能力</div>`;
        renderCapabilityDetails(selectedCapability());
        capabilitySelect.innerHTML = `<option value="">无匹配能力</option>`;
        capabilityRun.disabled = true;
        return;
    }
    const previous = capabilitySelect.value;
    capabilitySelect.innerHTML = caps
        .map((cap) => `<option value="${escapeHtml(cap.name)}">${escapeHtml(cap.name)} · ${escapeHtml(cap.kind)}</option>`)
        .join("");
    let selectionChanged = false;
    if (previous && caps.some((cap) => cap.name === previous)) {
        capabilitySelect.value = previous;
    }
    if (!capabilitySelect.value && caps[0]) {
        capabilitySelect.value = caps[0].name;
        selectionChanged = capabilitySelect.value !== previous;
    } else {
        selectionChanged = capabilitySelect.value !== previous;
    }
    if (selectionChanged) {
        applyCapabilityPreset(capabilitySelect.value);
    }
    ctxTools.innerHTML = caps
        .map(
            (cap) =>
                `<button class="tool-mini capability-card${cap.name === capabilitySelect.value ? " selected" : ""}" data-capability="${escapeHtml(cap.name)}" title="${escapeHtml(cap.description || "")}">
                    <span class="dot"></span>
                    <div class="tool-mini-body">
                        <span class="tool-name">${escapeHtml(cap.name)}</span>
                        <span class="tool-meta">${escapeHtml(cap.kind)} · ${escapeHtml(cap.source)} · ${escapeHtml(cap.streaming ? "stream" : "non-stream")} · ${escapeHtml(cap.risk_level)}</span>
                    </div>
                </button>`
        )
        .join("");
    renderCapabilityDetails(selectedCapability());
    ctxTools.querySelectorAll<HTMLButtonElement>("[data-capability]").forEach((el) => {
        el.addEventListener("click", () => {
            const name = String(el.dataset.capability ?? "");
            if (!name) return;
            const changed = capabilitySelect.value !== name;
            capabilitySelect.value = name;
            if (changed) {
                applyCapabilityPreset(name);
            }
            renderCapabilityMarketplace();
        });
    });
    capabilityRun.disabled = false;
}

function defaultCapabilityArgs(name: string): string {
    switch (name) {
        case "repo_map":
            return JSON.stringify({ max_depth: 3, max_entries: 40, include_files: false }, null, 2);
        case "code_search":
            return JSON.stringify({ query: "panel_server", max_results: 8, case_sensitive: false }, null, 2);
        case "workspace_briefing":
            return JSON.stringify({ query: "panel_server", search_max_results: 6 }, null, 2);
        case "github_repo_overview":
            return JSON.stringify({ recent_commit_count: 5 }, null, 2);
        case "github_diff_summary":
            return JSON.stringify({ max_files: 20, include_name_status: true }, null, 2);
        case "mcp_echo":
            return JSON.stringify({ text: "hello-from-mcp" }, null, 2);
        default:
            return "{}";
    }
}

function applyCapabilityPreset(name: string): void {
    const cap = capabilityCatalog.find((item) => item.name === name);
    capabilityArgs.value = defaultCapabilityArgs(cap?.name || name);
    capabilityResult.textContent = "";
}

async function loadCapabilities(prefetchedCaps?: CapabilityView[]): Promise<void> {
    try {
        if (prefetchedCaps) {
            renderCapabilities(prefetchedCaps);
            return;
        }
        const caps = (await RouterBinding.CallPanel("list_capabilities", {})) as Record<string, unknown>[];
        renderCapabilities((caps || []).map((item) => normalizeCapability(item)));
    } catch (e) {
        ctxTools.innerHTML = `<div class="tool-mini"><span class="dot off"></span>加载失败</div>`;
        capabilitySelect.innerHTML = `<option value="">加载失败</option>`;
        capabilityRun.disabled = true;
        console.warn("[hermes] list_capabilities:", e);
    }
}

async function checkBrainReady(): Promise<void> {
    try {
        const caps = (await RouterBinding.CallPanel("list_capabilities", {})) as Record<string, unknown>[];
        setBrainConnected(true);
        await loadCapabilities((caps || []).map((item) => normalizeCapability(item)));
        if (sessions.size === 0) {
            await createNewSession();
        }
        void refreshPendingApprovalsFromBrain();
        void loadProviders();
        void loadMemories();
        console.log("[hermes] brain connected");
    } catch (e) {
        console.log("[hermes] brain not ready, retry in 1s:", e);
        setTimeout(checkBrainReady, 1000);
    }
}

function setBrainConnected(connected: boolean): void {
    brainConnected = connected;
    if (connected) {
        brainDot.classList.remove("dead");
        brainStateText.textContent = "Erlang Brain · Connected";
        ctxStatus.textContent = "live";
        ctxConn.textContent = "connected";
        ctxConn.classList.remove("danger");
        ctxConn.classList.add("live");
    } else {
        brainDot.classList.add("dead");
        brainStateText.textContent = "Erlang Brain · Disconnected";
        ctxStatus.textContent = "down";
        ctxConn.textContent = "disconnected";
        ctxConn.classList.remove("live");
        ctxConn.classList.add("danger");
        backendPendingApprovals = [];
        disableComposer();
        stopStatusPolling();
        renderApprovalCenter();
    }
}

// ============================================================
// 新建聊天会话
// ============================================================
btnNewSession.addEventListener("click", () => {
    void createNewSession();
});

async function createNewSession(): Promise<void> {
    if (!brainConnected) {
        toast("Brain 未连接, 请稍候...");
        return;
    }
    const cfg = getConfigFromUI();
    saveConfig(cfg);

    const pendingId = `__pending__${Date.now()}`;
    const placeholder: Session = {
        id: pendingId,
        title: "...",
        model: cfg.model,
        createdAt: Date.now(),
        lastState: "thinking",
        msgCount: 0,
        toolCalls: 0,
        lastHistoryLen: 0,
        history: [],
        toolEvents: [],
        pendingApprovals: [],
    };
    sessions.set(pendingId, placeholder);
    currentSessionId = pendingId;
    renderSessionList({ animateId: pendingId });
    renderApprovalCenter();
    renderConversation(placeholder);
    disableComposer();

    try {
        btnNewSession.disabled = true;
        const req = new SessionStartRequest({
            system_prompt: cfg.systemPrompt,
            model: cfg.model,
            api_key: cfg.apiKey,
            api_base: cfg.apiBase,
        });
        const info = await HermesService.StartSession(req);
        if (!info?.session_id) {
            toast("StartSession 返回空 session_id");
            sessions.delete(pendingId);
            currentSessionId = null;
            renderSessionList();
            renderApprovalCenter();
            return;
        }
        sessions.delete(pendingId);
        const sess: Session = {
            id: info.session_id,
            title: `聊天 ${sessions.size + 1}`,
            model: cfg.model,
            createdAt: Date.now(),
            lastState: "idle",
            msgCount: 0,
            toolCalls: 0,
            lastHistoryLen: 0,
            history: [],
            toolEvents: [],
            pendingApprovals: [],
        };
        sessions.set(sess.id, sess);
        currentSessionId = sess.id;
        renderSessionList({ animateId: sess.id });
        renderApprovalCenter();
        renderConversation(sess);
        enableComposer();
        void pollBrainStatus();
        syncStatusPolling();
        updateModelBadge(cfg.model);
        console.log("[hermes] session started:", sess.id, "model=", cfg.model);
    } catch (e) {
        toast("StartSession 失败: " + e);
        sessions.delete(pendingId);
        currentSessionId = null;
        const remaining = [...sessions.values()];
        if (remaining.length > 0) {
            switchSession(remaining[remaining.length - 1].id);
        } else {
            conv.innerHTML = `<div class="empty-state"><div class="glyph">☿</div><div>开始与 Hermes 对话</div></div>`;
            canvasTitle.textContent = "Hermes Agent";
            canvasMeta.innerHTML = "";
        }
        renderSessionList();
        renderApprovalCenter();
    } finally {
        btnNewSession.disabled = false;
    }
}

// ============================================================
// 发送消息
// ============================================================
async function doSend(): Promise<void> {
    if (!currentSessionId) {
        toast("请先新建会话");
        return;
    }
    if (isSending) return;
    const text = prompt.value.trim();
    if (!text) return;

    isSending = true;
    btnSend.disabled = true;
    prompt.value = "";
    autoGrow();

    appendUserMsg(text);
    const sess = sessions.get(currentSessionId);
    if (sess) {
        appendCachedHistoryEntry(sess, { role: "user", content: text });
        sess.msgCount += 1;
        sess.lastHistoryLen += 1;
        sess.currentPlan = undefined;
        renderPlanPanel(sess);
        applySessionState(currentSessionId, "thinking", { historyLen: sess.lastHistoryLen });
        if (sess.msgCount === 1 && sess.title.startsWith("聊天 ")) {
            sess.title = text.length > 24 ? text.slice(0, 24) + "…" : text;
            canvasTitle.textContent = sess.title;
            updateSessionInList(sess.id);
        }
        updateCanvasMeta(sess);
    }

    appendThinking();
    updateSessionInList(currentSessionId);

    try {
        const result = await HermesService.Send(currentSessionId, text);
        const streamId = result?.stream_id ?? null;
        if (streamId) {
            sessionStreamIds.set(currentSessionId, streamId);
        } else {
            sessionStreamIds.delete(currentSessionId);
        }
        streamingText = "";
        streamingMsgEl = null;
        streamingMsgText = null;
    } catch (e) {
        removeThinking();
        toast("Send 失败: " + e);
    } finally {
        isSending = false;
        btnSend.disabled = false;
        if (currentSessionId) updateSessionInList(currentSessionId);
        syncStatusPolling();
        prompt.focus();
    }
}

btnSend.addEventListener("click", doSend);
prompt.addEventListener("keydown", (e) => {
    // ⌘+Enter (mac) 或 Ctrl+Enter 发送
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault();
        doSend();
    }
});
prompt.addEventListener("input", autoGrow);

function autoGrow(): void {
    prompt.style.height = "auto";
    prompt.style.height = Math.min(prompt.scrollHeight, 160) + "px";
}

// ============================================================
// Brain 状态轮询 (按需: 有发送/流式/FSM 活跃任务时才 tick)
// ============================================================

function shouldPollBrainStatus(): boolean {
    if (!currentSessionId || !brainConnected) return false;
    if (isSending || getStreamIdForSession(currentSessionId)) return true;
    const sess = sessions.get(currentSessionId);
    return sess?.lastState === "thinking" || sess?.lastState === "acting" || sess?.lastState === "waiting_approval";
}

/** 根据当前是否有待观察任务, 启动或停止轮询 */
function syncStatusPolling(): void {
    if (shouldPollBrainStatus()) {
        if (statusTimer === null) {
            statusTimer = window.setInterval(pollBrainStatus, STATUS_POLL_INTERVAL_MS);
            void pollBrainStatus();
        }
    } else {
        stopStatusPolling();
    }
    updateCancelButton();
}

function updateCancelButton(): void {
    const sess = currentSessionId ? sessions.get(currentSessionId) : null;
    const isRunning = isSending || getStreamIdForSession(currentSessionId) !== null ||
        sess?.lastState === "thinking" || sess?.lastState === "acting";
    btnCancel.style.display = isRunning ? "" : "none";
}

function stopStatusPolling(): void {
    if (statusTimer !== null) {
        clearInterval(statusTimer);
        statusTimer = null;
    }
}

async function pollBrainStatus(): Promise<void> {
    if (!currentSessionId) return;
    const sessionId = currentSessionId;
    try {
        const st = (await HermesService.BrainStatus(sessionId)) as Record<string, unknown>;
        updateBrainStatusUI(sessionId, st);
        const state = String(st.state ?? "unknown");
        if (state === "idle" && getStreamIdForSession(sessionId)) {
            // 流式终态若偶发丢失，看到 FSM 已回到 idle 时主动拉历史收敛 UI。
            sessionHistoryDirty.add(sessionId);
            await finalizeSessionUI(sessionId, "");
        }
    } catch (e) {
        console.warn("[hermes] brain_status error:", e);
    } finally {
        syncStatusPolling();
    }
}

function updateBrainStatusUI(sessionId: string, st: Record<string, unknown>): void {
    if (!st) return;
    const state = (st.state as string) || "unknown";
    const loop = (st.loop_count as number) ?? 0;
    const max = (st.max_loops as number) ?? 0;
    const hist = (st.history_len as number) ?? 0;
    const isCurrent = sessionId === currentSessionId;

    if (isCurrent) {
        ctxFsmState.textContent = state;
        ctxFsmState.className = "state-badge " + stateClass(state);
        ctxLoop.textContent = `${loop} / ${max}`;
        ctxHistory.textContent = String(hist);
    }

    const sess = sessions.get(sessionId);
    if (sess) {
        const prevState = sess.lastState;
        const nextState = sess.pendingApprovals.length > 0 ? "waiting_approval" : (state as BrainState);
        sess.lastState = nextState;
        sess.lastHistoryLen = hist;
        if (prevState !== sess.lastState) {
            updateSessionInList(sess.id);
        }

        if (!isCurrent) {
            return;
        }

        if (nextState === "thinking" || nextState === "acting") {
            if (!hasThinking()) appendThinking();
        } else if (nextState === "waiting_approval") {
            removeThinking();
        } else if (nextState === "idle") {
            const hasActiveStream = Boolean(getStreamIdForSession(sessionId));
            if (sessionHistoryDirty.has(sessionId) && !streamingMsgEl && !hasActiveStream) {
                removeThinking();
                sessionHistoryDirty.delete(sessionId);
                void refreshHistoryFromBrain();
            } else if (!hasActiveStream) {
                removeThinking();
            }
        }
    }
}

function stateClass(state: string): string {
    switch (state) {
        case "idle": return "s-idle";
        case "thinking": return "s-thinking";
        case "acting": return "s-acting";
        case "waiting_approval": return "s-acting";
        case "error": return "s-error";
        default: return "s-unknown";
    }
}

// ============================================================
// 渲染: session list (增量更新, 避免轮询时整表重绘闪烁)
// ============================================================

function sessionStatusLabel(sess: Session): string | null {
    const isCurrent = sess.id === currentSessionId;
    if (sess.pendingApprovals.length > 0) return "approve";
    if (isCurrent && (isSending || getStreamIdForSession(sess.id))) return "...";
    if (getStreamIdForSession(sess.id)) return "...";
    if (sess.lastState === "thinking" || sess.lastState === "acting") return "...";
    if (sess.lastState === "error") return "error";
    return null;
}

function sessionStatusClass(sess: Session): string {
    const label = sessionStatusLabel(sess);
    if (label === "...") return "st-wait";
    if (label === "error") return "st-error";
    return "st-idle";
}

function createSessionElement(sess: Session, animate: boolean): HTMLElement {
    const div = document.createElement("div");
    div.className = "session" + (sess.id === currentSessionId ? " active" : "") + (animate ? " session-new" : "");
    div.dataset.id = sess.id;
    const statusLabel = sessionStatusLabel(sess);
    const statusHtml = statusLabel
        ? `<span class="status-pill ${sessionStatusClass(sess)}">${statusLabel}</span>`
        : "";
    div.innerHTML = `
        <div class="session-row">
            <div class="session-body">
                <div class="session-title">${escapeHtml(sess.title)}</div>
                <div class="session-meta">
                    <span class="session-time">${formatTime(sess.createdAt)}</span>
                    <span class="session-model">${escapeHtml(sess.model)}</span>
                    ${statusHtml}
                </div>
            </div>
            <button type="button" class="session-del" title="删除会话" aria-label="删除会话">×</button>
        </div>
    `;
    bindSessionElement(div, sess.id);
    if (animate) {
        div.addEventListener("animationend", () => div.classList.remove("session-new"), { once: true });
    }
    return div;
}

function bindSessionElement(div: HTMLElement, id: string): void {
    div.querySelector(".session-body")!.addEventListener("click", () => switchSession(id));
    div.querySelector(".session-del")!.addEventListener("click", (ev) => {
        ev.stopPropagation();
        void deleteSession(id);
    });
}

function updateSessionElement(el: HTMLElement, sess: Session): void {
    el.classList.toggle("active", sess.id === currentSessionId);
    const titleEl = el.querySelector(".session-title") as HTMLElement | null;
    if (titleEl && titleEl.textContent !== sess.title) {
        titleEl.textContent = sess.title;
    }
    const modelEl = el.querySelector(".session-model") as HTMLElement | null;
    if (modelEl && modelEl.textContent !== sess.model) {
        modelEl.textContent = sess.model;
    }
    const metaEl = el.querySelector(".session-meta") as HTMLElement | null;
    if (!metaEl) return;
    let pillEl = metaEl.querySelector(".status-pill") as HTMLElement | null;
    const label = sessionStatusLabel(sess);
    if (!label) {
        pillEl?.remove();
        return;
    }
    if (!pillEl) {
        pillEl = document.createElement("span");
        metaEl.appendChild(pillEl);
    }
    pillEl.className = `status-pill ${sessionStatusClass(sess)}`;
    if (pillEl.textContent !== label) {
        pillEl.textContent = label;
    }
}

function updateSessionInList(id: string): void {
    const sess = sessions.get(id);
    if (!sess) return;
    const el = sessionList.querySelector(`[data-id="${CSS.escape(id)}"]`) as HTMLElement | null;
    if (el) updateSessionElement(el, sess);
}

function renderSessionList(opts?: { animateId?: string }): void {
    if (sessionCount) sessionCount.textContent = String(sessions.size);

    const alive = new Set<string>();
    for (const sess of sessions.values()) {
        alive.add(sess.id);
        let el = sessionList.querySelector(`[data-id="${CSS.escape(sess.id)}"]`) as HTMLElement | null;
        if (!el) {
            el = createSessionElement(sess, opts?.animateId === sess.id);
            sessionList.appendChild(el);
        } else {
            updateSessionElement(el, sess);
        }
    }
    for (const child of [...sessionList.children]) {
        const id = (child as HTMLElement).dataset.id;
        if (id && !alive.has(id)) child.remove();
    }
    renderApprovalCenter();
}

async function deleteSession(id: string): Promise<void> {
    if (id.startsWith("__pending__")) return;
    if (!brainConnected) {
        toast("Brain 未连接");
        return;
    }
    const sess = sessions.get(id);
    const label = sess?.title ?? id;
    if (!confirm(`删除会话「${label}」？\n将终止 Agent 并清除对话与记忆。`)) return;

    try {
        await HermesService.DeleteSession(id);
    } catch (e) {
        toast("删除失败: " + e);
        return;
    }

    sessions.delete(id);
    if (currentSessionId === id) {
        clearStreamState(id);
        isSending = false;
        stopStatusPolling();
        currentSessionId = null;
        const remaining = [...sessions.values()];
        if (remaining.length > 0) {
            switchSession(remaining[0].id);
        } else {
            conv.innerHTML = `<div class="empty-state"><div class="glyph">☿</div><div>开始与 Hermes 对话</div></div>`;
            canvasTitle.textContent = "Hermes Agent";
            canvasMeta.innerHTML = "";
            ctxFsmState.textContent = "—";
            ctxLoop.textContent = "—";
            ctxHistory.textContent = "0";
            disableComposer();
        }
    }
    renderSessionList();
    renderApprovalCenter();
    void refreshPendingApprovalsFromBrain();
    toast("会话已删除");
}

function switchSession(id: string): void {
    if (id.startsWith("__pending__")) return;
    currentSessionId = id;
    const sess = sessions.get(id);
    if (sess) {
        canvasTitle.textContent = sess.title;
        updateModelBadge(sess.model);
        if (sessionHistoryDirty.has(id)) {
            void refreshHistoryFromBrain(sess);
        } else {
            renderConversation(sess);
        }
        renderPlanPanel(sess);
        updateBrainStatusUI(id, {
            state: sess.lastState,
            loop_count: 0,
            max_loops: 0,
            history_len: sess.lastHistoryLen,
        });
    }
    for (const child of sessionList.children) {
        const el = child as HTMLElement;
        el.classList.toggle("active", el.dataset.id === id);
    }
    renderApprovalCenter();
    void refreshPendingApprovalsFromBrain();
    void pollBrainStatus();
    syncStatusPolling();
}

async function refreshHistoryFromBrain(sess?: Session): Promise<void> {
    const sid = sess?.id ?? currentSessionId;
    if (!sid || !brainConnected) return;
    const target = sess ?? sessions.get(sid);
    try {
        const entries = (await HermesService.GetHistory(sid)) as HistoryEntry[];
        renderHistoryEntries(entries, target);
        sessionHistoryDirty.delete(sid);
    } catch (e) {
        console.warn("[hermes] get_history error:", e);
    }
}

function renderHistoryEntries(entries: HistoryEntry[], sess?: Session): void {
    streamingMsgEl = null;
    streamingMsgText = null;
    conv.innerHTML = "";
    let userCount = 0;
    let toolCount = 0;
    for (const e of entries) {
        const role = (e.role || "").toLowerCase();
        if (role === "system") continue;
        const content = e.content || "";
        if (role === "user") {
            if (content) appendUserMsg(content);
            userCount += 1;
        } else if (role === "assistant") {
            if (content) appendAgentMsg(`<p>${escapeHtml(content)}</p>`);
            if ((e.tool_calls?.length ?? 0) > 0) toolCount += e.tool_calls!.length;
        } else if (role === "tool") {
            toolCount += 1;
            const label = e.tool_call_id ? `tool · ${e.tool_call_id}` : "tool";
            appendAgentMsg(`<p><small>${escapeHtml(label)}</small><br>${escapeHtml(content)}</p>`);
        }
    }
    if (userCount === 0 && toolCount === 0) {
        conv.innerHTML = `<div class="empty-state"><div class="glyph">☿</div><div>开始与 Hermes 对话</div></div>`;
    }
    if (sess) {
        cacheHistoryEntries(sess, entries);
        sess.msgCount = userCount;
        sess.toolCalls = toolCount;
        sess.lastHistoryLen = entries.length;
        updateCanvasMeta(sess);
        updateSessionInList(sess.id);
        renderTracePanel(sess);
    }
    scrollConvToBottom();
}

// ============================================================
// 渲染: conversation
// ============================================================
function renderConversation(sess: Session): void {
    if (sess.history.length > 0) {
        renderHistoryEntries(sess.history, sess);
        return;
    }
    streamingMsgEl = null;
    streamingMsgText = null;
    conv.innerHTML = "";
    if (sess.msgCount === 0) {
        conv.innerHTML = `<div class="empty-state"><div class="glyph">☿</div><div>开始与 Hermes 对话</div></div>`;
    }
    canvasTitle.textContent = sess.title;
    updateCanvasMeta(sess);
    renderTracePanel(sess);
    renderPlanPanel(sess);
}

function updateCanvasMeta(sess: Session): void {
    const approvalMeta = sess.pendingApprovals.length > 0
        ? ` · <b>${sess.pendingApprovals.length} 条待审批</b>`
        : "";
    canvasMeta.innerHTML = `<b>${sess.msgCount} 条消息</b> · <b>${sess.toolCalls} 次工具调用</b>${approvalMeta}`;
}

function normalizeApprovalRequest(raw: Record<string, unknown>): ApprovalRequest {
    const registeredAt = Number(raw.registered_at ?? raw.createdAt ?? Date.now());
    return {
        req_id: String(raw.req_id ?? ""),
        session_id: String(raw.session_id ?? ""),
        tool_call_id: String(raw.tool_call_id ?? raw.req_id ?? ""),
        tool_name: String(raw.tool_name ?? "unknown"),
        arguments_json: raw.arguments_json ? String(raw.arguments_json) : undefined,
        risk_level: String(raw.risk_level ?? "review"),
        expire_ms: Number(raw.expire_ms ?? 300000),
        createdAt: Number.isFinite(registeredAt) ? registeredAt : Date.now(),
    };
}

function syncPendingApprovalsToSessions(serverApprovals: ApprovalRequest[]): void {
    const bySession = new Map<string, ApprovalRequest[]>();
    for (const item of serverApprovals) {
        const list = bySession.get(item.session_id) ?? [];
        list.push({ ...item });
        bySession.set(item.session_id, list);
    }
    for (const sess of sessions.values()) {
        if (sess.id.startsWith("__pending__")) continue;
        sess.pendingApprovals = bySession.get(sess.id) ?? [];
        if (sess.pendingApprovals.length === 0 && sess.lastState === "waiting_approval") {
            sess.lastState = getStreamIdForSession(sess.id) ? "acting" : "idle";
        }
    }
}

async function refreshPendingApprovalsFromBrain(): Promise<void> {
    if (!brainConnected) return;
    try {
        const raw = (await RouterBinding.CallPanel("list_pending_approvals", {})) as Record<string, unknown>[];
        backendPendingApprovals = Array.isArray(raw) ? raw.map((item) => normalizeApprovalRequest(item)) : [];
        syncPendingApprovalsToSessions(backendPendingApprovals);
        renderSessionList();
        const current = currentSessionId ? sessions.get(currentSessionId) : null;
        if (current) {
            updateCanvasMeta(current);
            renderTracePanel(current);
        }
    } catch (e) {
        console.warn("[hermes] list_pending_approvals:", e);
    }
}

function listApprovalCenterEntries(): ApprovalCenterEntry[] {
    const entries = new Map<string, ApprovalCenterEntry>();
    for (const item of backendPendingApprovals) {
        const sess = sessions.get(item.session_id);
        entries.set(item.req_id, {
            ...item,
            session_title: sess?.title ?? item.session_id,
            session_model: sess?.model ?? "unknown",
            is_current: item.session_id === currentSessionId,
        });
    }
    for (const sess of sessions.values()) {
        if (sess.id.startsWith("__pending__")) continue;
        for (const item of sess.pendingApprovals) {
            if (entries.has(item.req_id)) continue;
            entries.set(item.req_id, {
                ...item,
                session_title: sess.title,
                session_model: sess.model,
                is_current: sess.id === currentSessionId,
            });
        }
    }
    return [...entries.values()].sort((a, b) => a.createdAt - b.createdAt);
}

function approvalTTL(item: ApprovalRequest): string {
    const age = Math.max(Date.now() - item.createdAt, 0);
    if (item.expire_ms <= 0) return "—";
    return `${Math.max(Math.floor((item.expire_ms - age) / 1000), 0)}s`;
}

function removeApprovalByReqId(reqId: string): string[] {
    const affected: string[] = [];
    backendPendingApprovals = backendPendingApprovals.filter((item) => item.req_id !== reqId);
    for (const sess of sessions.values()) {
        if (!sess.pendingApprovals.some((item) => item.req_id === reqId)) continue;
        sess.pendingApprovals = sess.pendingApprovals.filter((item) => item.req_id !== reqId);
        affected.push(sess.id);
    }
    return affected;
}

function renderApprovalCenter(): void {
    const allApprovals = listApprovalCenterEntries();
    approvalCount.textContent = String(allApprovals.length);
    const scope = approvalScope.value;
    const approvals = scope === "current"
        ? allApprovals.filter((item) => item.session_id === currentSessionId)
        : allApprovals;

    if (approvals.length === 0) {
        const emptyText = scope === "current"
            ? (currentSessionId ? "当前会话暂无待审批项" : "请先选择会话")
            : "暂无待审批项";
        approvalCenter.innerHTML = `<div class="approval-empty">${escapeHtml(emptyText)}</div>`;
        return;
    }

    approvalCenter.innerHTML = approvals.map((item) => {
        const args = item.arguments_json ? truncate(item.arguments_json, 120) : "";
        const currentClass = item.is_current ? " current" : "";
        return `
            <div class="approval-card${currentClass}">
                <div class="approval-card-head">
                    <div class="approval-tool">${escapeHtml(item.tool_name)}</div>
                    <div class="approval-risk">${escapeHtml(item.risk_level)}</div>
                </div>
                <div class="approval-meta">
                    会话: <b>${escapeHtml(item.session_title)}</b> · ${escapeHtml(item.session_model)} · 剩余 ${approvalTTL(item)}
                </div>
                ${args ? `<div class="approval-args">入参: <code>${escapeHtml(args)}</code></div>` : ""}
                <div class="approval-actions">
                    <button class="approval-btn" data-action="jump" data-session-id="${escapeHtml(item.session_id)}">跳转会话</button>
                    <button class="approval-btn primary" data-action="approve" data-session-id="${escapeHtml(item.session_id)}" data-req-id="${escapeHtml(item.req_id)}">批准</button>
                    <button class="approval-btn danger" data-action="reject" data-session-id="${escapeHtml(item.session_id)}" data-req-id="${escapeHtml(item.req_id)}">拒绝</button>
                </div>
            </div>
        `;
    }).join("");

    approvalCenter.querySelectorAll<HTMLButtonElement>(".approval-btn").forEach((btn) => {
        btn.addEventListener("click", () => {
            const action = String(btn.dataset.action ?? "");
            const sessionId = String(btn.dataset.sessionId ?? "");
            const reqId = String(btn.dataset.reqId ?? "");
            if (action === "jump") {
                if (sessionId) switchSession(sessionId);
                return;
            }
            btn.disabled = true;
            void resolveApproval(sessionId, reqId, action === "approve").finally(() => {
                btn.disabled = false;
            });
        });
    });
}

function handleApprovalRequired(sessionId: string, payload: Record<string, unknown>, updateCurrentUI: boolean): void {
    const sess = sessions.get(sessionId);
    if (!sess) return;
    const reqId = String(payload.req_id ?? "");
    if (!reqId || sess.pendingApprovals.some((item) => item.req_id === reqId)) {
        return;
    }
    const req: ApprovalRequest = {
        req_id: reqId,
        session_id: String(payload.session_id ?? sessionId),
        tool_call_id: String(payload.tool_call_id ?? reqId),
        tool_name: String(payload.tool_name ?? "unknown"),
        arguments_json: payload.arguments_json ? String(payload.arguments_json) : undefined,
        risk_level: String(payload.risk_level ?? "review"),
        expire_ms: Number(payload.expire_ms ?? 300000),
        createdAt: Date.now(),
    };
    sess.pendingApprovals.push(req);
    applySessionState(sessionId, "waiting_approval", { updateCurrentUI });
    updateCanvasMeta(sess);
    renderTracePanel(sess);
    renderApprovalCenter();
    updateSessionInList(sessionId);
    if (updateCurrentUI && sessionId === currentSessionId) {
        removeThinking();
        appendAgentMsg(
            `<p><small>approval required</small><br>` +
            `能力 <b>${escapeHtml(req.tool_name)}</b> 需要审批，风险等级：${escapeHtml(req.risk_level)}。</p>`
        );
    }
    toast(`待审批能力: ${req.tool_name} (${req.risk_level})`);
    void refreshPendingApprovalsFromBrain();
    syncStatusPolling();
}

function normalizePlanSteps(stepsRaw: unknown): PlanStep[] {
    if (!Array.isArray(stepsRaw)) return [];
    return stepsRaw.map((s, idx) => {
        const step = s as Record<string, unknown>;
        return {
            index: Number(step.index ?? idx + 1),
            description: String(step.description ?? ""),
            tool_hint: step.tool_hint ? String(step.tool_hint) : undefined,
            risk_level: String(step.risk_level ?? "low"),
            expected: step.expected ? String(step.expected) : undefined,
            note: step.note ? String(step.note) : undefined,
            status: "pending",
        };
    });
}

function handlePlanGenerated(sessionId: string, payload: Record<string, unknown>, updateCurrentUI: boolean): void {
    const sess = sessions.get(sessionId);
    if (!sess) return;
    const plan: ExecutionPlan = {
        goal: String(payload.goal ?? ""),
        steps: normalizePlanSteps(payload.steps),
        warnings: Array.isArray(payload.warnings) ? payload.warnings.map((w) => String(w)) : [],
        suggestions: Array.isArray(payload.suggestions) ? payload.suggestions.map((s) => String(s)) : [],
    };
    sess.currentPlan = plan;
    if (updateCurrentUI && sessionId === currentSessionId) {
        renderPlanPanel(sess);
        appendAgentMsg(
            `<p><small>📋 执行计划已生成</small><br><b>目标:</b> ${escapeHtml(plan.goal)}</p>`
        );
    }
}

function handlePlanStepUpdate(sessionId: string, payload: Record<string, unknown>): void {
    const sess = sessions.get(sessionId);
    if (!sess?.currentPlan) return;
    const stepIndex = Number(payload.step_index ?? 0);
    const status = String(payload.status ?? "pending") as PlanStep["status"];
    const resultSummary = payload.result_summary ? String(payload.result_summary) : undefined;
    const step = sess.currentPlan.steps.find((s) => s.index === stepIndex);
    if (step) {
        step.status = status;
        if (resultSummary) step.result_summary = resultSummary;
    }
    if (sessionId === currentSessionId) {
        renderPlanPanel(sess);
    }
}

function renderPlanPanel(sess: Session): void {
    let panel = document.getElementById("plan-panel");
    if (!panel) {
        panel = document.createElement("section");
        panel.id = "plan-panel";
        panel.className = "plan-panel";
        const tracePanel = document.getElementById("trace-panel");
        if (tracePanel) {
            tracePanel.insertAdjacentElement("beforebegin", panel);
        } else {
            conv.insertAdjacentElement("afterend", panel);
        }
    }
    const plan = sess.currentPlan;
    if (!plan) {
        panel.classList.remove("visible");
        panel.innerHTML = "";
        return;
    }
    panel.classList.add("visible");
    const riskClass = (r: string) => {
        if (r === "high") return "risk-high";
        if (r === "medium") return "risk-medium";
        return "risk-low";
    };
    const statusIcon = (status?: string) => {
        switch (status) {
            case "running": return "⏳";
            case "done": return "✅";
            case "failed": return "❌";
            case "skipped": return "⏭️";
            default: return "◻️";
        }
    };
    const stepsHtml = plan.steps.map((step) => `
        <div class="plan-step ${step.status ?? "pending"}">
            <div class="plan-step-head">
                <span class="plan-step-idx">${step.index}</span>
                <span class="plan-step-status">${statusIcon(step.status)}</span>
                <span class="plan-step-desc">${escapeHtml(step.description)}</span>
                ${step.tool_hint ? `<span class="plan-step-tool">${escapeHtml(step.tool_hint)}</span>` : ""}
                <span class="plan-step-risk ${riskClass(step.risk_level)}">${escapeHtml(step.risk_level)}</span>
            </div>
            ${step.expected ? `<div class="plan-step-note">→ ${escapeHtml(step.expected)}</div>` : ""}
            ${step.note ? `<div class="plan-step-note warning">${escapeHtml(step.note)}</div>` : ""}
            ${step.result_summary ? `<div class="plan-step-result">${escapeHtml(step.result_summary)}</div>` : ""}
        </div>
    `).join("");
    const warningsHtml = plan.warnings.length > 0
        ? `<div class="plan-warnings">${plan.warnings.map((w) => `<div class="plan-warning">⚠️ ${escapeHtml(w)}</div>`).join("")}</div>`
        : "";
    const suggestionsHtml = plan.suggestions.length > 0
        ? `<div class="plan-suggestions">${plan.suggestions.map((s) => `<div class="plan-suggestion">📌 ${escapeHtml(s)}</div>`).join("")}</div>`
        : "";
    panel.innerHTML = `
        <div class="plan-header">
            <span class="plan-title">📋 执行计划 (${plan.steps.length} 步)</span>
            <span class="plan-goal">目标: ${escapeHtml(truncate(plan.goal, 80))}</span>
        </div>
        <div class="plan-steps">${stepsHtml}</div>
        ${warningsHtml}
        ${suggestionsHtml}
    `;
}

async function resolveApproval(sessionId: string, reqId: string, allow: boolean): Promise<void> {
    const sess = sessions.get(sessionId);
    if (!sess && !reqId) return;
    try {
        const out = (await RouterBinding.CallPanel("approve", {
            req_id: reqId,
            allow,
        })) as Record<string, unknown>;
        const ok = Boolean(out?.ok ?? out?.OK);
        if (!ok) {
            throw new Error(String(out?.error ?? "approve failed"));
        }
        const affectedSessionIds = removeApprovalByReqId(reqId);
        for (const affectedId of affectedSessionIds) {
            updateSessionInList(affectedId);
        }
        const activeSessionId = affectedSessionIds[0] ?? sessionId;
        const activeSession = sessions.get(activeSessionId);
        if (activeSession) {
            const nextState: BrainState = activeSession.pendingApprovals.length > 0 ? "waiting_approval" : "acting";
            applySessionState(activeSessionId, nextState);
            if (activeSessionId === currentSessionId) {
                updateCanvasMeta(activeSession);
                renderTracePanel(activeSession);
            }
        }
        renderApprovalCenter();
        void refreshPendingApprovalsFromBrain();
        toast(allow ? "已批准能力执行" : "已拒绝能力执行");
    } catch (e) {
        toast("审批失败: " + e);
    } finally {
        syncStatusPolling();
    }
}

// EXEC-P1-005: 处理 tool_event 帧 payload。
// 同一 tool_call_id 先收到 finished=false (开始), 后收到 finished=true (结束/失败)。
// 已结束的 trace 不再覆盖, 新 tool_call_id 追加新条目。
function handleToolEvent(sess: Session, payload: Record<string, unknown>): void {
    const toolCallId = String(payload.tool_call_id ?? "");
    const name = String(payload.name ?? "");
    const finished = Boolean(payload.finished);
    const argumentsJson = payload.arguments_json !== undefined && payload.arguments_json !== ""
        ? String(payload.arguments_json) : undefined;
    const resultJson = payload.result_json !== undefined && payload.result_json !== ""
        ? String(payload.result_json) : undefined;
    const error = payload.error !== undefined && payload.error !== ""
        ? String(payload.error) : undefined;

    if (!toolCallId) return;

    // 结束事件: 按 tool_call_id 找已有开始事件并更新
    if (finished) {
        const existing = sess.toolEvents.find((e) => e.tool_call_id === toolCallId && !e.finished);
        if (existing) {
            existing.finished = true;
            existing.finishedAt = Date.now();
            if (resultJson !== undefined) existing.result_json = resultJson;
            if (error !== undefined) existing.error = error;
            return;
        }
        // 找不到开始事件: 推一条已结束的条目 (兼容老协议)
        sess.toolEvents.push({
            tool_call_id: toolCallId,
            name,
            finished: true,
            finishedAt: Date.now(),
            startedAt: Date.now(),
            result_json: resultJson,
            error,
        });
        return;
    }

    // 开始事件: 追加新条目
    sess.toolEvents.push({
        tool_call_id: toolCallId,
        name,
        arguments_json: argumentsJson,
        finished: false,
        startedAt: Date.now(),
    });
}

// EXEC-P1-005: 渲染 trace 面板 (当前会话的工具执行轨迹)。
// 容器动态创建在 conversation 与 composer 之间, 无 trace 时隐藏。
function renderTracePanel(sess: Session): void {
    let panel = document.getElementById("trace-panel");
    if (!panel) {
        panel = document.createElement("section");
        panel.id = "trace-panel";
        panel.className = "trace-panel";
        conv.insertAdjacentElement("afterend", panel);
    }
    const events = sess.toolEvents;
    const approvals = sess.pendingApprovals;
    if (events.length === 0 && approvals.length === 0) {
        panel.classList.remove("visible");
        panel.innerHTML = "";
        return;
    }
    panel.classList.add("visible");
    const approvalItems = approvals.map((item) => {
        const age = Math.max(Date.now() - item.createdAt, 0);
        const ttl = item.expire_ms > 0 ? `${Math.max(Math.floor((item.expire_ms - age) / 1000), 0)}s` : "—";
        const args = item.arguments_json ? truncate(item.arguments_json, 160) : "";
        return `
            <div class="trace-item trace-failed">
                <div class="trace-head">
                    <span class="trace-status trace-status-failed">待审批</span>
                    <span class="trace-name">${escapeHtml(item.tool_name)}</span>
                    <span class="trace-id">#${escapeHtml(item.tool_call_id.slice(0, 8))}</span>
                    <span class="trace-duration">${ttl}</span>
                </div>
                <div class="trace-error"><span class="trace-label">风险:</span> <code>${escapeHtml(item.risk_level)}</code></div>
                ${args ? `<div class="trace-args"><span class="trace-label">入参:</span> <code>${escapeHtml(args)}</code></div>` : ""}
                <div class="trace-actions">
                    <button class="trace-approve" data-session-id="${escapeHtml(sess.id)}" data-req-id="${escapeHtml(item.req_id)}">批准</button>
                    <button class="trace-reject" data-session-id="${escapeHtml(sess.id)}" data-req-id="${escapeHtml(item.req_id)}">拒绝</button>
                </div>
            </div>
        `;
    }).join("");
    const items = events.map((ev) => {
        const status = ev.finished
            ? (ev.error ? "failed" : "done")
            : "running";
        const statusText = ev.finished
            ? (ev.error ? "失败" : "完成")
            : "执行中";
        const duration = ev.finished && ev.finishedAt
            ? `${Math.max(ev.finishedAt - ev.startedAt, 0)}ms`
            : "—";
        const args = ev.arguments_json ? truncate(ev.arguments_json, 120) : "";
        const result = ev.result_json ? truncate(ev.result_json, 200) : "";
        const errText = ev.error ? escapeHtml(ev.error) : "";
        return `
            <div class="trace-item trace-${status}">
                <div class="trace-head">
                    <span class="trace-status trace-status-${status}">${statusText}</span>
                    <span class="trace-name">${escapeHtml(ev.name || ev.tool_call_id)}</span>
                    <span class="trace-id">#${escapeHtml(ev.tool_call_id.slice(0, 8))}</span>
                    <span class="trace-duration">${duration}</span>
                </div>
                ${args ? `<div class="trace-args"><span class="trace-label">入参:</span> <code>${escapeHtml(args)}</code></div>` : ""}
                ${result ? `<div class="trace-result"><span class="trace-label">结果:</span> <code>${escapeHtml(result)}</code></div>` : ""}
                ${errText ? `<div class="trace-error"><span class="trace-label">错误:</span> <code>${errText}</code></div>` : ""}
            </div>
        `;
    }).join("");
    panel.innerHTML = `
        <div class="trace-header">
            <span class="trace-title">执行轨迹 (${events.length}${approvals.length > 0 ? ` + ${approvals.length} 待审批` : ""})</span>
            <button class="trace-clear" id="trace-clear" title="清空轨迹">×</button>
        </div>
        <div class="trace-list">${approvalItems}${items}</div>
    `;
    const clearBtn = panel.querySelector("#trace-clear") as HTMLButtonElement | null;
    if (clearBtn) {
        clearBtn.addEventListener("click", () => {
            sess.toolEvents = [];
            renderTracePanel(sess);
        });
    }
    panel.querySelectorAll(".trace-approve").forEach((btn) => {
        btn.addEventListener("click", () => {
            const el = btn as HTMLButtonElement;
            el.disabled = true;
            void resolveApproval(
                String(el.dataset.sessionId ?? sess.id),
                String(el.dataset.reqId ?? ""),
                true
            ).finally(() => {
                el.disabled = false;
            });
        });
    });
    panel.querySelectorAll(".trace-reject").forEach((btn) => {
        btn.addEventListener("click", () => {
            const el = btn as HTMLButtonElement;
            el.disabled = true;
            void resolveApproval(
                String(el.dataset.sessionId ?? sess.id),
                String(el.dataset.reqId ?? ""),
                false
            ).finally(() => {
                el.disabled = false;
            });
        });
    });
}

function truncate(s: string, max: number): string {
    return s.length <= max ? s : s.slice(0, max) + "…";
}

function appendUserMsg(text: string): void {
    removeEmptyState();
    const msg = document.createElement("div");
    msg.className = "msg msg-user";
    msg.innerHTML = `
        <div class="msg-role">
            <div class="user-role-dot">Z</div>
            <span>YOU</span>
        </div>
        <div class="msg-body"><p>${escapeHtml(text)}</p></div>
    `;
    conv.appendChild(msg);
    scrollConvToBottom();
}

function appendAgentMsg(html: string): void {
    removeEmptyState();
    const msg = document.createElement("div");
    msg.className = "msg msg-agent";
    msg.innerHTML = `
        <div class="msg-role">
            <div class="agent-avatar">☿</div>
            <span>HERMES</span>
        </div>
        <div class="msg-body">${html}</div>
    `;
    conv.appendChild(msg);
    scrollConvToBottom();
}

function appendThinking(): void {
    if (hasThinking()) return;
    removeEmptyState();
    const el = document.createElement("div");
    el.className = "msg thinking";
    el.innerHTML = `
        <div class="msg-role">
            <div class="agent-avatar">☿</div>
            <span>HERMES · THINKING</span>
        </div>
        <div class="think-orb"><span></span><span></span><span></span></div>
    `;
    conv.appendChild(el);
    scrollConvToBottom();
}

function removeThinking(): void {
    conv.querySelectorAll(".thinking").forEach((el) => el.remove());
}

function hasThinking(): boolean {
    return conv.querySelector(".thinking") !== null;
}

function removeEmptyState(): void {
    conv.querySelectorAll(".empty-state").forEach((el) => el.remove());
}

function scrollConvToBottom(): void {
    conv.scrollTop = conv.scrollHeight;
}

// ============================================================
// composer 状态
// ============================================================
function enableComposer(): void {
    prompt.disabled = false;
    btnSend.disabled = false;
    prompt.focus();
}

function disableComposer(): void {
    prompt.disabled = true;
    btnSend.disabled = true;
}

// ============================================================
// topbar / canvas actions
// ============================================================
btnStop.addEventListener("click", async () => {
    if (!confirm("确认停止 Erlang Brain?")) return;
    try {
        await HermesService.StopBrain();
        setBrainConnected(false);
        toast("Erlang Brain 已停止");
    } catch (e) {
        toast("StopBrain 失败: " + e);
    }
});

btnCancel.addEventListener("click", async () => {
    if (!currentSessionId) return;
    btnCancel.disabled = true;
    try {
        await RouterBinding.CallPanel("cancel_execution", { session_id: currentSessionId });
        toast("已发送取消指令");
    } catch (e) {
        toast("取消失败: " + e);
    } finally {
        setTimeout(() => { btnCancel.disabled = false; }, 1000);
    }
});

btnShutdown.addEventListener("click", () => btnStop.click());

btnClear.addEventListener("click", () => {
    if (!currentSessionId) return;
    if (!confirm("清空当前会话消息?")) return;
    const sess = sessions.get(currentSessionId);
    if (sess) {
        sess.history = [];
        sess.msgCount = 0;
        sess.toolCalls = 0;
        sess.lastHistoryLen = 0;
        sess.pendingApprovals = [];
        sess.toolEvents = [];
        sess.currentPlan = undefined;
        renderConversation(sess);
        renderPlanPanel(sess);
        renderApprovalCenter();
        void refreshPendingApprovalsFromBrain();
    }
});

// ============================================================
// 工具
// ============================================================
const HTML_ESCAPES: Record<string, string> = {
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
};

function escapeHtml(s: string): string {
    return s.replace(/[&<>"']/g, (c) => HTML_ESCAPES[c]);
}

function formatTime(ts: number): string {
    const d = new Date(ts);
    return d.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });
}

let toastTimer: number | null = null;
function toast(msg: string): void {
    console.log("[toast]", msg);
    let el = document.getElementById("toast");
    if (!el) {
        el = document.createElement("div");
        el.id = "toast";
        el.style.cssText =
            "position:fixed;bottom:24px;left:50%;transform:translateX(-50%);" +
            "background:var(--surface-2);border:1px solid var(--border-2);color:var(--ink);" +
            "padding:10px 16px;border-radius:8px;font-family:var(--mono);font-size:12px;" +
            "z-index:10000;box-shadow:0 4px 20px rgba(0,0,0,.4);transition:opacity .3s";
        document.body.appendChild(el);
    }
    el.textContent = msg;
    el.style.opacity = "1";
    if (toastTimer !== null) clearTimeout(toastTimer);
    toastTimer = window.setTimeout(() => {
        if (el) el.style.opacity = "0";
    }, 2500);
}

// ============================================================
// Provider 配置面板
// ============================================================

interface Provider {
    id: string;
    name: string;
    provider_type: string;
    endpoint?: string;
    model?: string;
    is_default?: boolean;
    is_enabled?: boolean;
    last_error?: string;
}

async function loadProviders(): Promise<void> {
    try {
        const resp = (await RouterBinding.CallPanel("list_providers", {})) as { providers?: Provider[] };
        renderProviders(resp.providers || []);
    } catch (e) {
        console.warn("[hermes] list_providers failed:", e);
        providersList.innerHTML = '<div class="providers-empty">加载失败</div>';
    }
}

function renderProviders(providers: Provider[]): void {
    if (!providers || providers.length === 0) {
        providersList.innerHTML = '<div class="providers-empty">暂无Provider配置</div>';
        return;
    }
    providersList.innerHTML = providers
        .map((p) => {
            const status = p.last_error
                ? `<span class="p-status err">${escapeHtml(p.last_error)}</span>`
                : p.is_enabled === false
                  ? '<span class="p-status err">已禁用</span>'
                  : '<span class="p-status">● 正常</span>';
            const defBadge = p.is_default ? ' <span class="p-type" style="background:rgba(232,165,64,.12);color:var(--accent)">DEFAULT</span>' : '';
            return `<div class="provider-card">
                <div class="p-row">
                    <span class="p-name">${escapeHtml(p.name || p.id)}${defBadge}</span>
                    <span class="p-type">${escapeHtml(p.provider_type || 'unknown')}</span>
                </div>
                ${p.endpoint ? `<div class="p-endpoint">${escapeHtml(p.endpoint)}</div>` : ''}
                ${p.model ? `<div class="p-endpoint">model: ${escapeHtml(p.model)}</div>` : ''}
                <div class="p-row"><span></span>${status}</div>
            </div>`;
        })
        .join("");
}

btnRefreshProviders.addEventListener("click", () => {
    void loadProviders();
});

// ============================================================
// 分层记忆面板
// ============================================================

interface MemoryItem {
    key: string;
    tier: string;
    content: string;
    source?: string;
    created_at?: number;
    session_id?: string;
}

async function loadMemories(): Promise<void> {
    try {
        const tierVal = memoryTierFilter.value;
        const args: Record<string, string> = { session_id: "global" };
        if (tierVal !== "all") {
            args.tier = tierVal;
        }
        const resp = (await RouterBinding.CallPanel("list_memories", args)) as { memories?: MemoryItem[] };
        renderMemories(resp.memories || []);
    } catch (e) {
        console.warn("[hermes] list_memories failed:", e);
        memoriesList.innerHTML = '<div class="memories-empty">加载失败</div>';
    }
}

function renderMemories(memories: MemoryItem[]): void {
    if (!memories || memories.length === 0) {
        memoriesList.innerHTML = '<div class="memories-empty">暂无记忆</div>';
        return;
    }
    const sorted = [...memories].sort((a, b) => (b.created_at || 0) - (a.created_at || 0));
    memoriesList.innerHTML = sorted
        .map((m) => {
            const time = m.created_at ? new Date(m.created_at).toLocaleString() : "";
            const tier = m.tier || "facts";
            return `<div class="memory-item" data-key="${escapeHtml(m.key)}" data-tier="${escapeHtml(tier)}">
                <div class="m-tier ${escapeHtml(tier)}">${escapeHtml(tier)}${m.source === 'manual' ? ' · manual' : ''}</div>
                <div class="m-content">${escapeHtml(m.content || '')}</div>
                <div class="m-meta">
                    <span class="m-time">${escapeHtml(time)}</span>
                    <button class="m-del" title="删除" data-action="del-memory">×</button>
                </div>
            </div>`;
        })
        .join("");
}

memoryTierFilter.addEventListener("change", () => {
    void loadMemories();
});

btnRefreshMemories.addEventListener("click", () => {
    void loadMemories();
});

btnAddMemory.addEventListener("click", async () => {
    const content = memoryAddContent.value.trim();
    if (!content) {
        toast("请输入记忆内容");
        return;
    }
    const tier = memoryAddTier.value;
    btnAddMemory.disabled = true;
    try {
        await RouterBinding.CallPanel("add_memory", {
            session_id: "global",
            tier: tier,
            content: content,
        });
        memoryAddContent.value = "";
        toast("记忆已添加");
        await loadMemories();
    } catch (e) {
        toast("添加失败: " + e);
    } finally {
        btnAddMemory.disabled = false;
    }
});

memoriesList.addEventListener("click", async (ev) => {
    const target = ev.target as HTMLElement;
    if (target.dataset.action !== "del-memory") return;
    const card = target.closest(".memory-item") as HTMLElement | null;
    if (!card) return;
    const key = card.dataset.key || "";
    const tier = card.dataset.tier || "facts";
    if (!key) return;
    try {
        await RouterBinding.CallPanel("delete_memory", {
            session_id: "global",
            tier: tier,
            key: key,
        });
        toast("已删除");
        await loadMemories();
    } catch (e) {
        toast("删除失败: " + e);
    }
});
