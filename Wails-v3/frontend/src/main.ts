// Hermes Agent Workbench — 前端入口
//
// 与 Go 侧 HermesService (Wails v3 binding) 交互:
//   HermesService.StartSession(prompt)  → 派发 agent_fsm
//   HermesService.Send(sid, msg)        → 触发 ReAct (异步, 立即返回 stream_id)
//   HermesService.BrainStatus(sid)      → 读 FSM 状态 (idle/thinking/acting)
//   HermesService.ListTools()           → 工具列表
//   HermesService.StopBrain()            → 优雅停止 Erlang 大脑
//
// 当前限制: send 是 cast 触发, 不返回 final answer。
// 前端通过轮询 brain_status 推断 ReAct 进度, agent 响应文本拉取待后续 get_history RPC 接入。

import { HermesService } from "../bindings/hermes";

// ---- 类型 ----
type BrainState = "idle" | "thinking" | "acting" | "unknown" | "not_found" | "error";

interface Session {
    id: string;
    title: string;
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

// ---- DOM ----
const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const conv = $("conv")!;
const prompt = $("prompt") as HTMLTextAreaElement;
const btnSend = $("btn-send") as HTMLButtonElement;
const btnNewSession = $("btn-new-session") as HTMLButtonElement;
const btnStop = $("btn-stop") as HTMLButtonElement;
const btnShutdown = $("btn-shutdown") as HTMLButtonElement;
const btnClear = $("btn-clear") as HTMLButtonElement;
const sessionList = $("session-list")!;
const sessionCount = $("session-count")!;
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
setTimeout(checkBrainReady, 500);

async function checkBrainReady(): Promise<void> {
    try {
        // list_tools 不需要 session, 适合探活
        await HermesService.ListTools();
        setBrainConnected(true);
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
// 新建会话
// ============================================================
btnNewSession.addEventListener("click", async () => {
    if (!brainConnected) {
        toast("Brain 未连接, 请稍候...");
        return;
    }
    try {
        btnNewSession.disabled = true;
        const info = await HermesService.StartSession("");
        if (!info?.session_id) {
            toast("StartSession 返回空 session_id");
            return;
        }
        const sess: Session = {
            id: info.session_id,
            title: `Session ${sessions.size + 1}`,
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
        console.log("[hermes] session started:", sess.id);
    } catch (e) {
        toast("StartSession 失败: " + e);
    } finally {
        btnNewSession.disabled = false;
    }
});

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
        updateCanvasMeta(sess);
    }

    appendThinking();

    try {
        await HermesService.Send(currentSessionId, text);
        console.log("[hermes] send triggered, polling brain_status...");
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
            if (hist > sess.lastHistoryLen) {
                removeThinking();
                appendAgentMsg(
                    `Brain 已完成此轮 ReAct 循环 (loop=${loop}/${max}, history=${hist})。<br>` +
                    `<span style="color:var(--ink-3);font-size:12px">Final answer 通过 Erlang history 可查 (待后续 get_history RPC 接入前端展示)。</span>`
                );
            } else {
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
    sessionCount.textContent = String(sessions.size);
    sessionList.innerHTML = "";
    for (const sess of sessions.values()) {
        const div = document.createElement("div");
        div.className = "session" + (sess.id === currentSessionId ? " active" : "");
        div.dataset.id = sess.id;
        div.innerHTML = `
            <div class="session-title">${escapeHtml(sess.title)}</div>
            <div class="session-meta">
                <span class="session-time">${formatTime(sess.createdAt)}</span>
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
    if (sess) renderConversation(sess);
    renderSessionList();
    startStatusPolling();
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
