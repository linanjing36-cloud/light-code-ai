// Hermes Agent Workbench — 前端入口
//
// 与 Go 侧 HermesService (Wails v3 binding) 交互:
//   HermesService.StartSession(prompt)  → 派发 agent_fsm
//   HermesService.Send(sid, msg)        → 触发 ReAct (异步, 立即返回 stream_id)
//   HermesService.BrainStatus(sid)      → 读 FSM 状态 (idle/thinking/acting)
//   HermesService.GetHistory(sid)       → 拉取 state_store 短期记忆
//   HermesService.ListTools()           → 工具列表
//   HermesService.StopBrain()            → 优雅停止 Erlang 大脑
//
// 流式 chunk/final 由 panel:stream 事件驱动; 终态后 get_history 同步对话区。

import { HermesService } from "../bindings/hermes";
import { SessionStartRequest } from "../bindings/hermes/models.js";

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
}

// ---- 状态 ----
let currentSessionId: string | null = null;
const sessions = new Map<string, Session>();
let brainConnected = false;
let statusTimer: number | null = null;
let isSending = false;
let currentStreamId: string | null = null;
let streamingMsgEl: HTMLElement | null = null;
let streamingText = "";

// ---- Wails 流式事件 (panel_server → Bridge → EmitEvent) ----
declare global {
    interface Window {
        wails?: {
            Events?: {
                On: (name: string, cb: (ev: { name: string; data: PanelStreamEvent }) => void) => () => void;
            };
        };
    }
}

interface HistoryEntry {
    role: string;
    content: string;
    tool_calls_json?: string;
    tool_call_id?: string;
}

interface PanelStreamEvent {
    stream_id: string;
    kind: "chunk" | "tool_event" | "final" | "error" | "unknown";
    payload: Record<string, unknown>;
}

function setupStreamListener(): void {
    window.wails?.Events?.On("panel:stream", (ev) => {
        handlePanelStream(ev.data);
    });
}
setupStreamListener();

function handlePanelStream(ev: PanelStreamEvent): void {
    if (!ev || !currentStreamId || ev.stream_id !== currentStreamId) return;
    console.log("[hermes] stream", ev.kind, ev.stream_id);
    switch (ev.kind) {
        case "chunk": {
            const part = String(ev.payload.content ?? "");
            if (part) {
                streamingText += part;
                ensureStreamingMsg();
                if (streamingMsgEl) {
                    streamingMsgEl.innerHTML = `<p>${escapeHtml(streamingText)}</p>`;
                    scrollConvToBottom();
                }
            }
            break;
        }
        case "final": {
            removeThinking();
            resetStreamState();
            void refreshHistoryFromBrain();
            break;
        }
        case "error": {
            removeThinking();
            appendAgentMsg(`<p style="color:var(--danger)">${escapeHtml(String(ev.payload.message ?? "stream error"))}</p>`);
            resetStreamState();
            break;
        }
        case "tool_event": {
            const sess = currentSessionId ? sessions.get(currentSessionId) : undefined;
            if (sess) {
                sess.toolCalls += 1;
                updateCanvasMeta(sess);
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
    conv.appendChild(streamingMsgEl);
}

function resetStreamState(): void {
    currentStreamId = null;
    streamingMsgEl = null;
    streamingText = "";
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
// 启动: Bridge.ServiceStartup 已由 Wails 自动调用 (拉起 Erlang + 连 panel_server)
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

async function loadToolsList(): Promise<void> {
    try {
        const tools = await HermesService.ListTools();
        if (!tools?.length) {
            ctxTools.innerHTML = `<div class="tool-mini"><span class="dot off"></span>无可用工具</div>`;
            return;
        }
        ctxTools.innerHTML = tools
            .map(
                (t) =>
                    `<div class="tool-mini" title="${escapeHtml(t.description || "")}"><span class="dot"></span>${escapeHtml(t.name || "")}</div>`
            )
            .join("");
    } catch (e) {
        ctxTools.innerHTML = `<div class="tool-mini"><span class="dot off"></span>加载失败</div>`;
        console.warn("[hermes] list_tools:", e);
    }
}

async function checkBrainReady(): Promise<void> {
    try {
        // list_tools 不需要 session, 适合探活
        await HermesService.ListTools();
        setBrainConnected(true);
        await loadToolsList();
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
            return;
        }
        const sess: Session = {
            id: info.session_id,
            title: `聊天 ${sessions.size + 1}`,
            model: cfg.model,
            createdAt: Date.now(),
            lastState: "idle",
            msgCount: 0,
            toolCalls: 0,
            lastHistoryLen: 0,
        };
        sessions.set(sess.id, sess);
        currentSessionId = sess.id;
        renderSessionList();
        renderConversation(sess);
        enableComposer();
        startStatusPolling();
        updateModelBadge(cfg.model);
        console.log("[hermes] session started:", sess.id, "model=", cfg.model);
    } catch (e) {
        toast("StartSession 失败: " + e);
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
        sess.msgCount += 1;
        if (sess.msgCount === 1 && sess.title.startsWith("聊天 ")) {
            sess.title = text.length > 24 ? text.slice(0, 24) + "…" : text;
            canvasTitle.textContent = sess.title;
            renderSessionList();
        }
        updateCanvasMeta(sess);
    }

    appendThinking();

    try {
        const result = await HermesService.Send(currentSessionId, text);
        currentStreamId = result?.stream_id ?? null;
        streamingText = "";
        streamingMsgEl = null;
        console.log("[hermes] send triggered stream_id=", currentStreamId);
    } catch (e) {
        removeThinking();
        toast("Send 失败: " + e);
    } finally {
        isSending = false;
        btnSend.disabled = false;
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
// Brain 状态轮询
// ============================================================
function startStatusPolling(): void {
    stopStatusPolling();
    statusTimer = window.setInterval(pollBrainStatus, 1000);
    pollBrainStatus();
}

function stopStatusPolling(): void {
    if (statusTimer !== null) {
        clearInterval(statusTimer);
        statusTimer = null;
    }
}

async function pollBrainStatus(): Promise<void> {
    if (!currentSessionId) return;
    try {
        const st = await HermesService.BrainStatus(currentSessionId);
        updateBrainStatusUI(st as Record<string, unknown>);
    } catch (e) {
        console.warn("[hermes] brain_status error:", e);
    }
}

function updateBrainStatusUI(st: Record<string, unknown>): void {
    if (!st) return;
    const state = (st.state as string) || "unknown";
    const loop = (st.loop_count as number) ?? 0;
    const max = (st.max_loops as number) ?? 0;
    const hist = (st.history_len as number) ?? 0;

    ctxFsmState.textContent = state;
    ctxFsmState.className = "state-badge " + stateClass(state);
    ctxLoop.textContent = `${loop} / ${max}`;
    ctxHistory.textContent = String(hist);

    const sess = sessions.get(currentSessionId!);
    if (sess) {
        sess.lastState = state as BrainState;
        renderSessionList();

        // ReAct 循环状态机:
        //   thinking → acting → (回 thinking) → idle
        // 思考中/执行中: 保持 thinking 动画
        // 回到 idle 且 history_len 增加: ReAct 完成, 显示占位 agent 消息
        if (state === "thinking" || state === "acting") {
            if (!hasThinking()) appendThinking();
        } else if (state === "idle") {
            if (hist > sess.lastHistoryLen && !streamingMsgEl && !currentStreamId) {
                removeThinking();
                void refreshHistoryFromBrain();
            } else if (state === "idle" && !currentStreamId) {
                removeThinking();
            }
            sess.lastHistoryLen = hist;
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
// 渲染: session list
// ============================================================
function renderSessionList(): void {
    if (sessionCount) sessionCount.textContent = String(sessions.size);
    sessionList.innerHTML = "";
    for (const sess of sessions.values()) {
        const div = document.createElement("div");
        div.className = "session" + (sess.id === currentSessionId ? " active" : "");
        div.dataset.id = sess.id;
        div.innerHTML = `
            <div class="session-title">${escapeHtml(sess.title)}</div>
            <div class="session-meta">
                <span class="session-time">${formatTime(sess.createdAt)}</span>
                <span class="session-model">${escapeHtml(sess.model)}</span>
                <span class="status-pill ${pillClass(sess.lastState)}">${sess.lastState}</span>
            </div>
        `;
        div.addEventListener("click", () => switchSession(sess.id));
        sessionList.appendChild(div);
    }
}

function pillClass(state: BrainState): string {
    switch (state) {
        case "thinking": return "st-running";
        case "acting": return "st-running";
        case "idle": return "st-idle";
        case "error": return "st-error";
        default: return "st-idle";
    }
}

function switchSession(id: string): void {
    currentSessionId = id;
    const sess = sessions.get(id);
    if (sess) {
        canvasTitle.textContent = sess.title;
        updateModelBadge(sess.model);
        void refreshHistoryFromBrain(sess);
    }
    renderSessionList();
    startStatusPolling();
}

async function refreshHistoryFromBrain(sess?: Session): Promise<void> {
    const sid = currentSessionId;
    if (!sid || !brainConnected) return;
    const target = sess ?? sessions.get(sid);
    try {
        const entries = (await HermesService.GetHistory(sid)) as HistoryEntry[];
        renderHistoryEntries(entries, target);
    } catch (e) {
        console.warn("[hermes] get_history error:", e);
    }
}

function renderHistoryEntries(entries: HistoryEntry[], sess?: Session): void {
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
            if (e.tool_calls_json) toolCount += 1;
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
        sess.msgCount = userCount;
        sess.toolCalls = toolCount;
        updateCanvasMeta(sess);
    }
    scrollConvToBottom();
}

// ============================================================
// 渲染: conversation
// ============================================================
function renderConversation(sess: Session): void {
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
        sess.msgCount = 0;
        sess.toolCalls = 0;
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
