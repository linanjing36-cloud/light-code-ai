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
type BrainState = "idle" | "thinking" | "acting" | "unknown" | "not_found" | "error";

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
}

// ---- 状态 ----
let currentSessionId: string | null = null;
const sessions = new Map<string, Session>();
let brainConnected = false;
let statusTimer: number | null = null;
let isSending = false;
const sessionStreamIds = new Map<string, string>();
const sessionHistoryDirty = new Set<string>();
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
    kind: "chunk" | "tool_event" | "final" | "error" | "unknown";
    payload: Record<string, unknown>;
}

interface CapabilityView {
    name: string;
    description: string;
    kind: string;
    source: string;
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
        if (ev.kind === "final" || ev.kind === "error") {
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
                if (targetSessionId === currentSessionId) {
                    updateCanvasMeta(sess);
                }
            }
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
        if (!needsHistoryRefresh) {
            appendCachedHistoryEntry(sess, { role: "assistant", content: finalContent });
        }
        applySessionState(sessionId, "idle", {
            historyLen: needsHistoryRefresh ? sess.lastHistoryLen + 1 : sess.history.length,
        });
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
const capabilitySelect = $("capability-select") as HTMLSelectElement;
const capabilityArgs = $("capability-args") as HTMLTextAreaElement;
const capabilityRun = $("capability-run") as HTMLButtonElement;
const capabilityResult = $("capability-result") as HTMLElement;
const btnStop = $("btn-stop") as HTMLButtonElement;
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

capabilitySelect.addEventListener("change", () => {
    applyCapabilityPreset(capabilitySelect.value);
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
        risk_level: String(raw.risk_level || "safe"),
        cost_hint: String(raw.cost_hint || "low"),
        tags: Array.isArray(raw.tags) ? raw.tags.map((tag) => String(tag)) : [],
        input_schema: raw.input_schema,
    };
}

function renderCapabilities(caps: CapabilityView[]): void {
    capabilityCatalog = caps;
    if (!caps.length) {
        ctxTools.innerHTML = `<div class="tool-mini"><span class="dot off"></span>无可用能力</div>`;
        capabilitySelect.innerHTML = `<option value="">暂无能力</option>`;
        capabilityArgs.value = "{}";
        capabilityResult.textContent = "";
        capabilityRun.disabled = true;
        return;
    }
    ctxTools.innerHTML = caps
        .map(
            (cap) =>
                `<div class="tool-mini" title="${escapeHtml(cap.description || "")}">
                    <span class="dot"></span>
                    <div class="tool-mini-body">
                        <span class="tool-name">${escapeHtml(cap.name)}</span>
                        <span class="tool-meta">${escapeHtml(cap.kind)} · ${escapeHtml(cap.source)} · ${escapeHtml(cap.risk_level)}</span>
                    </div>
                </div>`
        )
        .join("");
    capabilitySelect.innerHTML = caps
        .map((cap) => `<option value="${escapeHtml(cap.name)}">${escapeHtml(cap.name)} · ${escapeHtml(cap.kind)}</option>`)
        .join("");
    if (!capabilitySelect.value && caps[0]) {
        capabilitySelect.value = caps[0].name;
    }
    applyCapabilityPreset(capabilitySelect.value);
    capabilityRun.disabled = false;
}

function defaultCapabilityArgs(name: string): string {
    switch (name) {
        case "repo_map":
            return JSON.stringify({ max_depth: 3, max_entries: 40, include_files: false }, null, 2);
        case "code_search":
            return JSON.stringify({ query: "panel_server", max_results: 8, case_sensitive: false }, null, 2);
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
        disableComposer();
        stopStatusPolling();
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
    };
    sessions.set(pendingId, placeholder);
    currentSessionId = pendingId;
    renderSessionList({ animateId: pendingId });
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
        };
        sessions.set(sess.id, sess);
        currentSessionId = sess.id;
        renderSessionList({ animateId: sess.id });
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
    return sess?.lastState === "thinking" || sess?.lastState === "acting";
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
        sess.lastState = state as BrainState;
        sess.lastHistoryLen = hist;
        if (prevState !== sess.lastState) {
            updateSessionInList(sess.id);
        }

        if (!isCurrent) {
            return;
        }

        if (state === "thinking" || state === "acting") {
            if (!hasThinking()) appendThinking();
        } else if (state === "idle") {
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
        case "error": return "s-error";
        default: return "s-unknown";
    }
}

// ============================================================
// 渲染: session list (增量更新, 避免轮询时整表重绘闪烁)
// ============================================================

function sessionStatusLabel(sess: Session): string | null {
    const isCurrent = sess.id === currentSessionId;
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
}

function updateCanvasMeta(sess: Session): void {
    canvasMeta.innerHTML = `<b>${sess.msgCount} 条消息</b> · <b>${sess.toolCalls} 次工具调用</b>`;
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
        renderConversation(sess);
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
