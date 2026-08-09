  const NAV_ICON = {
    fleet: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>',
    inbox: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/><path d="M12 9v4M12 17h.01"/></svg>',
    techtree: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="8" r="3"/><path d="M6 9v6"/><path d="M18 11a9 9 0 0 1-9 9"/></svg>',
    analytics: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3v18h18"/><rect x="7" y="12" width="3" height="5"/><rect x="12" y="8" width="3" height="9"/><rect x="17" y="5" width="3" height="12"/></svg>',
    streamdeck: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="4" width="20" height="16" rx="2.5"/><circle cx="7" cy="9" r="1.7"/><circle cx="12" cy="9" r="1.7"/><circle cx="17" cy="9" r="1.7"/><circle cx="7" cy="15" r="1.7"/><circle cx="12" cy="15" r="1.7"/><circle cx="17" cy="15" r="1.7"/></svg>',
  };
  const PAGE_META = {
    fleet: { title: "Units", sub: "Every agent in the current run" },
    inbox: { title: "Commands", sub: "Decisions waiting on your call" },
    techtree: { title: "Build Order", sub: "Dependency graph across epics" },
    analytics: { title: "Analytics", sub: "Live run utilization" },
    streamdeck: { title: "Streamdeck+", sub: "Stream Deck + control surface" },
  };
  function switchTab(tab) {
    activeTab = tab;
    $$(".panel").forEach((p) => p.classList.toggle("is-active", p.dataset.panel === tab));
    $$(".snav").forEach((b) => b.classList.toggle("is-active", b.dataset.tab === tab));
    const meta = PAGE_META[tab] || PAGE_META.fleet;
    const t = $("#page-head-title"); if (t) t.textContent = meta.title;
    const ic = $("#page-head-ic"); if (ic) ic.innerHTML = NAV_ICON[tab] || NAV_ICON.fleet;
    const recent = $("#recent-card"); if (recent) recent.style.display = tab === "fleet" ? "" : "none";
    const phr = $("#page-head-run"); if (phr) phr.style.display = tab === "fleet" ? "" : "none";
    window.scrollTo({ top: 0, behavior: "smooth" });
    if (tab === "techtree") renderBuildOrder();
    if (tab === "analytics" && window.AiurAnalytics) window.AiurAnalytics.render();
    if (tab === "streamdeck") initStreamdeck();
  }
  /* ============================================================
     STREAMDECK — Stream Deck + emulator (live agent surface)
     ============================================================ */
  let sdInit = false;
  const sdDials = [0, 0, 0];        // knobs A/B/C — unassigned, free-rotating
  let sdAgents = [], sdColOff = 0, sdMaxOff = 0, sdWindows = 1, sdKnob3 = 0;
  let sdLog = [], sdFlat = [], sdEvStart = [], sdEventIdx = 0, sdSel = 0, sdChatIdx = 0, sdKnobA = 0;
  let sdLivePhrase = 0, sdLiveTimer = null;
  const SD_LIVE_PHRASES = ["Building\u2026", "Running tests\u2026", "Writing changes\u2026", "Pushing branch\u2026", "Reading files\u2026", "Reasoning\u2026"];
  const SD_LOG_DIR = {
    emit:    { l: "EMIT",    c: "#9fd0ff" },
    consume: { l: "CONSUME", c: "#88e0a6" },
    info:    { l: "INFO",    c: "#c2c6cf" },
    agent:   { l: "AGENT",   c: "#9fd0ff" },
    system:  { l: "SYSTEM",  c: "#ffcf87" },
  };
  const SD_ST = {
    running: { glow: "linear-gradient(180deg,#3f8bff,#7b4bf5)", face: "linear-gradient(180deg,#18212d,#0f151d)", accent: "#9fd0ff", label: "Running" },
    paused:  { glow: "linear-gradient(180deg,#4a4d55,#33363d)", face: "linear-gradient(180deg,#1e2025,#131419)", accent: "#c2c6cf", label: "Paused" },
    stuck:   { glow: "linear-gradient(180deg,#ff6a5e,#c0392b)", face: "linear-gradient(180deg,#271317,#160c0e)", accent: "#ff9a90", label: "Stuck" },
    alert:   { glow: "linear-gradient(180deg,#ffc061,#e08a1e)", face: "linear-gradient(180deg,#241d0e,#15110a)", accent: "#ffcf87", label: "Needs input" },
    queued:  { glow: "linear-gradient(180deg,#3a3f47,#23262c)", face: "linear-gradient(180deg,#191b21,#111318)", accent: "#9096a4", label: "Unstarted" },
  };
  const SD_RANK = { alert: 0, stuck: 1, running: 2, paused: 3, queued: 4 };
  let sdMode = "grid", sdActive = null;
  function sdStateOf(f) {
    const b = bucketOf(f);
    if (b === "stuck") return "stuck";
    if (b === "paused") return "paused";
    if (b === "alert") return "alert";
    if (b === "queued") return "queued";
    return "running";
  }
  function sdReady(f) {
    return (f.blockedBy || []).every((bid) => { const b = fleet.find((x) => x.id === bid); return b && (b.pct >= 100 || b.control === "Merged"); });
  }
  const SD_PRIO_IC = '<svg viewBox="0 0 24 24" fill="currentColor" stroke="none"><path d="M12 3l2.6 5.7 6.2.6-4.7 4.2 1.4 6.1L12 17l-5.5 2.6 1.4-6.1L3.2 9.3l6.2-.6z"/></svg>';
  const SD_CMD_IC = {
    back: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 6l-6 6 6 6"/></svg>',
    pause: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="none"><rect x="6.5" y="5" width="3.6" height="14" rx="1"/><rect x="13.9" y="5" width="3.6" height="14" rx="1"/></svg>',
    play: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="none"><path d="M8 5.5v13l11-6.5z"/></svg>',
    up: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M6 11l6-6 6 6"/></svg>',
    down: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M6 13l6 6 6-6"/></svg>',
    mic: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M6 11a6 6 0 0 0 12 0M12 17v4"/></svg>',
    logs: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6h16M4 12h16M4 18h10"/></svg>',
  };
  function sdApplyRot(i, val) {
    const knob = $("#sd-knob-" + i);
    if (knob) knob.style.setProperty("--a", (-135 + (val / 100) * 270).toFixed(1) + "deg");
  }
  function sdSetDial(i, v) { sdDials[i] = Math.max(0, Math.min(100, Math.round(v))); sdApplyRot(i, sdDials[i]); }
  function sdKnobDelta(i, inc) {
    if (i === 3) {
      sdKnob3 = Math.max(0, Math.min(100, sdKnob3 + inc));
      sdApplyRot(3, sdKnob3);
      if (sdMode === "logs") {
        const maxStart = Math.max(0, sdLog.length - 8);
        const idx = maxStart > 0 ? Math.round((sdKnob3 / 100) * maxStart) : 0;
        if (idx !== sdEventIdx) { sdEventIdx = idx; sdRenderLogKeys($("#sd-keys")); const h = $("#sd-evhint"); if (h) h.innerHTML = sdEvHint(); }
        return;
      }
      if (sdMode !== "grid") return;
      const off = sdMaxOff > 0 ? Math.round((sdKnob3 / 100) * sdMaxOff) : 0;
      if (off !== sdColOff) { sdColOff = off; sdRenderKeys(); sdRenderPager(); }
      return;
    }
    if (i === 0 && sdMode === "logs") {
      sdKnobA = Math.max(0, Math.min(100, sdKnobA + inc));
      sdApplyRot(0, sdKnobA);
      const len = sdFlat.length;
      const maxC = sdChatMax();
      const idx = maxC - Math.round((sdKnobA / 100) * maxC);
      if (idx !== sdChatIdx) {
        sdChatIdx = idx;
        const ev = sdFlat[idx].ev;
        if (ev !== sdSel) { sdSel = ev; sdEnsureVisible(); sdRenderLogKeys($("#sd-keys")); const h = $("#sd-evhint"); if (h) h.innerHTML = sdEvHint(); }
        sdBuildLogStrip();
      }
      return;
    }
    sdSetDial(i, sdDials[i] + inc);
  }
  function sdStopCol(w) { return Math.min(w * 4, sdMaxOff); }
  function sdCurWin() { let w = 0; for (let i = 0; i < sdWindows; i++) if (sdColOff >= sdStopCol(i)) w = i; return w; }
  function sdCycleWindow() {
    if (sdMode === "grid") {
      if (sdWindows <= 1) return;
      const next = (sdCurWin() + 1) % sdWindows;
      sdColOff = sdStopCol(next);
      sdKnob3 = sdMaxOff > 0 ? (sdColOff / sdMaxOff) * 100 : 0; // sync without rotating on press
      sdRenderKeys(); sdRenderPager();
      return;
    }
    if (sdMode === "logs") {
      const pages = Math.max(1, Math.ceil(sdLog.length / 8));
      if (pages <= 1) return;
      const next = (Math.floor(sdEventIdx / 8) + 1) % pages;
      sdEventIdx = next * 8;
      const maxStart = Math.max(0, sdLog.length - 8);
      sdKnob3 = maxStart > 0 ? (Math.min(sdEventIdx, maxStart) / maxStart) * 100 : 0; // sync without rotating
      sdRenderLogKeys($("#sd-keys"));
      const h = $("#sd-evhint"); if (h) h.innerHTML = sdEvHint();
      return;
    }
  }
  function sdResetView() { sdColOff = 0; sdKnob3 = 0; sdApplyRot(3, 0); sdRenderKeys(); sdRenderPager(); }
  function sdRenderKeys() {
    const wrap = $("#sd-keys"); if (!wrap) return;
    wrap.dataset.screen = sdMode === "grid" ? "agents" : (sdMode === "cmd" ? "agent" : "logs");
    if (sdMode === "cmd" && sdActive) { sdRenderCmdKeys(wrap); return; }
    if (sdMode === "logs" && sdActive) { sdRenderLogKeys(wrap); return; }
    let html = "";
    for (let i = 0; i < 8; i++) {
      const col = i % 4, row = i < 4 ? 0 : 1;
      const f = sdAgents[(sdColOff + col) * 2 + row];
      if (!f) { html += '<button class="sd-key sd-empty" type="button" disabled aria-hidden="true"><span class="sd-key-face"></span></button>'; continue; }
      const st = sdStateOf(f), c = SD_ST[st];
      const pct = Math.max(0, Math.min(100, f.pct));
      const hue = (pct / 100 * 125).toFixed(0);
      const prio = f._prio ? '<span class="sd-ag-prio" title="Prioritized">' + SD_PRIO_IC + '</span>' : '';
      let foot;
      if (st === "queued") {
        const rdy = sdReady(f);
        foot = '<span class="sd-ag-foot col"><span class="sd-ag-stat" style="color:' + c.accent + '">' + c.label + '</span>' +
               '<span class="sd-ag-tag ' + (rdy ? "ready" : "blocked") + '">' + (rdy ? "Unblocked" : "Blocked") + '</span></span>';
      } else {
        foot = '<span class="sd-ag-foot"><span class="sd-ag-dot" style="background:' + c.accent + '"></span><span class="sd-ag-bar"><i style="width:' + pct + '%;background:hsl(' + hue + ' 72% 50%)"></i></span></span>';
      }
      html +=
        '<button class="sd-key sd-agent-key st-' + st + '" type="button" data-id="' + f.id + '" style="background:' + c.glow + '">' +
          '<span class="sd-key-face sd-agent" style="background:' + c.face + '">' +
            '<span class="sd-agent-top"><span class="sd-ag-ic" style="color:' + c.accent + '">' + boIcon(f.icon) + '</span><img class="sd-ag-vendor" src="assets/' + (f.claude ? 'claude-symbol.svg' : 'codex-color.svg') + '" alt="" /><span class="sd-ag-idwrap">' + prio + '<span class="sd-ag-id">' + f.num + '</span></span></span>' +
            '<span class="sd-ag-title">' + esc(f.title) + '</span>' +
            foot +
          '</span>' +
        '</button>';
    }
    wrap.innerHTML = html;
    wrap.querySelectorAll(".sd-agent-key").forEach((b) => {
      b.addEventListener("click", () => {
        b.classList.remove("flash"); void b.offsetWidth; b.classList.add("flash");
        const f = fleet.find((x) => x.id === b.dataset.id);
        if (f) sdEnterCmd(f);
      });
    });
  }
  function sdRenderCmdKeys(wrap) {
    const f = sdActive;
    const paused = f.control === "Paused";
    const prio = !!f._prio;
    const cmds = [
      { id: "pause", ic: paused ? SD_CMD_IC.play : SD_CMD_IC.pause, label: paused ? "Play" : "Pause", sub: paused ? "RESUME" : "HOLD", tint: "#ffcf87" },
      { id: "prio",  ic: prio ? SD_CMD_IC.down : SD_CMD_IC.up, label: prio ? "Deprioritize" : "Prioritize", sub: prio ? "LOWER" : "RAISE", tint: "#9fd0ff" },
      { id: "logs",  ic: SD_CMD_IC.logs, label: "Logs", sub: "SCROLL", tint: "#9fd0ff" },
      { id: "mic",   ic: SD_CMD_IC.mic, label: "Mic", sub: "HOLD", tint: "#7fe0a0", mic: true },
    ];
    let html = "";
    for (let i = 0; i < 8; i++) {
      const cmd = cmds[i];
      if (!cmd) { html += '<button class="sd-key sd-empty" type="button" disabled aria-hidden="true"><span class="sd-key-face"></span></button>'; continue; }
      html +=
        '<button class="sd-key sd-cmd-key' + (cmd.mic ? ' sd-mic-key' : '') + '" type="button" data-cmd="' + cmd.id + '">' +
          '<span class="sd-key-face"><span class="sd-cmd"><span class="sd-cmd-ic" style="color:' + cmd.tint + '">' + cmd.ic + '</span><span class="sd-cmd-label">' + cmd.label + '</span></span></span>' +
        '</button>';
    }
    wrap.innerHTML = html;
    wrap.querySelectorAll(".sd-cmd-key").forEach((b) => {
      if (b.classList.contains("sd-mic-key")) {
        const on = (e) => { e.preventDefault(); b.classList.add("mic-live"); };
        const off = () => b.classList.remove("mic-live");
        b.addEventListener("pointerdown", on);
        b.addEventListener("pointerup", off);
        b.addEventListener("pointerleave", off);
        b.addEventListener("pointercancel", off);
        return;
      }
      b.addEventListener("click", () => {
        b.classList.remove("flash"); void b.offsetWidth; b.classList.add("flash");
        sdRunCmd(b.dataset.cmd);
      });
    });
  }
  function sdEnterCmd(f) { sdMode = "cmd"; sdActive = f; sdRenderKeys(); sdBuildCmdStrip(f); }
  function sdRunCmd(id) {
    const f = sdActive; if (!f) return;
    if (id === "back") { sdMode = "grid"; sdActive = null; sdRenderKeys(); sdRenderPager(); return; }
    if (id === "logs") { sdEnterLogs(); return; }
    if (id === "pause") {
      if (typeof togglePause === "function") togglePause(f);
      else f.control = f.control === "Paused" ? "Running" : "Paused";
      if (typeof renderFleet === "function") renderFleet();
      if (typeof updateTabCounts === "function") updateTabCounts();
      toast("accent", f.control === "Paused" ? "Paused" : "Resumed", "AIUR-" + f.num + " \u00b7 " + f.title);
      sdRenderKeys(); sdBuildCmdStrip(f);
    }
    if (id === "prio") {
      f._prio = !f._prio;
      toast("accent", f._prio ? "Prioritized" : "Deprioritized", "AIUR-" + f.num + " \u00b7 " + f.title);
      sdRenderKeys(); sdBuildCmdStrip(f);
    }
  }
  function sdMini(lbl, pct, meta) {
    const r = meta ? (pct + '% \u00b7 ' + meta) : (pct + '%');
    return '<div class="sd-mini"><div class="sd-mini-top"><span class="sd-mini-lbl">' + lbl + '</span><span class="sd-mini-r">' + r + '</span></div>' +
      '<div class="sd-mini-bar"><i style="width:' + pct + '%"></i></div></div>';
  }
  function sdBuildGridStrip() {
    const screen = $("#sd-screen"); if (!screen) return;
    screen.innerHTML =
      '<div class="sd-seg sd-seg-info"><div class="sd-info-hd"><img class="sd-hd-logo" src="assets/aiur-logo.png" alt="" />SUMMARY</div><div class="sd-info-live"><b>10</b> live \u00b7 <b>20</b> left</div>' + sdMini("Build", 65, "ETA 58m") + '</div>' +
      '<div class="sd-seg sd-seg-info"><div class="sd-info-hd"><img class="sd-hd-logo" src="assets/claude-symbol.svg" alt="" />Claude</div>' + sdMini("Session", 28, "22m") + sdMini("Weekly", 47, "Thu 6PM") + '</div>' +
      '<div class="sd-seg sd-seg-info"><div class="sd-info-hd"><img class="sd-hd-logo" src="assets/codex-color.svg" alt="" />Codex</div>' + sdMini("Session", 19, "40m") + sdMini("Weekly", 31, "Mon 9AM") + '</div>' +
      '<div class="sd-seg sd-seg-d" id="sd-seg-d"><span class="sd-seg-dlabel">MORE AGENTS</span><div class="sd-pager-nav"><div class="sd-pg-dots"></div></div><span class="sd-pager-label"></span></div>';
  }
  function sdBuildCmdStrip(f) {
    const screen = $("#sd-screen"); if (!screen || !f) return;
    const st = SD_ST[sdStateOf(f)];
    const pct = Math.max(0, Math.min(100, f.pct));
    const hue = (pct / 100 * 125).toFixed(0);
    const vendor = f.claude ? "assets/claude-symbol.svg" : "assets/codex-color.svg";
    screen.innerHTML = '<div class="sd-cmd-page">' +
      '<div class="sd-ci-main">' +
        '<span class="sd-ci-ic" style="color:' + st.accent + '">' + boIcon(f.icon) + '</span>' +
        '<img class="sd-ci-vendor" src="' + vendor + '" alt="" />' +
        '<span class="sd-ci-id">' + f.num + '</span>' +
        '<span class="sd-ci-title">' + esc(f.title) + '</span>' +
        '<span class="sd-ci-status" style="color:' + st.accent + '">' + st.label + '</span>' +
        '<span class="sd-ci-pct">' + pct + '%</span>' +
      '</div>' +
      '<div class="sd-ci-bar"><i style="width:' + pct + '%;background:hsl(' + hue + ' 72% 50%)"></i></div>' +
      '<div class="sd-log-hints"><span class="sd-log-hint a">BACK</span><span></span><span></span><span></span></div>' +
    '</div>';
  }
  function sdBuildLog(f) {
    const pr = 200 + (f.num % 90);
    const heads = [
      ["just now", "info", "Awaiting your review on PR #" + pr],
      ["3m ago", "emit", "Opened PR #" + pr],
      ["7m ago", "consume", "CI passed \u2014 214 tests green"],
      ["12m ago", "emit", "Pushed feat/token-service"],
      ["18m ago", "consume", "Ran the full test suite"],
      ["25m ago", "emit", "Wrote token refresh logic"],
      ["32m ago", "emit", "Extracted TokenService class"],
      ["40m ago", "info", "Chose base branch: main + cherry-pick"],
      ["49m ago", "consume", "Reviewed auth middleware"],
      ["58m ago", "emit", "Drafted the extraction plan"],
      ["1h 8m ago", "emit", "Refactored session store access"],
      ["1h 19m ago", "consume", "Reproduced the token-expiry bug"],
      ["1h 31m ago", "emit", "Added structured error envelopes"],
      ["1h 44m ago", "consume", "Rate limit \u2014 backed off 40s"],
      ["1h 58m ago", "emit", "Prototyped an in-memory token cache"],
      ["2h 13m ago", "consume", "Indexed the repository"],
      ["2h 29m ago", "info", "Clarified acceptance criteria"],
      ["2h 46m ago", "emit", "Set up the working branch"],
      ["3h 4m ago", "consume", "Consumed repo snapshot + ticket"],
      ["3h 23m ago", "info", "Session started"],
      ["1d 2h ago", "emit", "Parked overnight \u2014 pushed WIP branch"],
      ["1d 6h ago", "consume", "Reviewed prior attempt on this ticket"],
      ["2d ago", "info", "Picked up after triage; read the design doc"],
      ["4d ago", "info", "Ticket created and assigned"],
    ];
    return heads.map((h, i) => ({ t: h[0], dir: h[1], text: h[2], chat: sdGenChat(i, f) }));
  }
  function sdGenChat(i, f) {
    const files = ["src/auth/token.ts", "src/auth/session.ts", "src/auth/middleware.ts", "src/errors/envelope.ts", "src/http/router.ts", "test/auth/token.spec.ts"];
    const syms = ["TokenService", "refresh", "verifyToken", "SessionStore", "errorEnvelope", "withAuth"];
    const fp = (n) => files[(i * 2 + n) % files.length];
    const sp = (n) => syms[(i * 3 + n) % syms.length];
    const num = (n, mod, base) => base + ((i * 7 + n * 11) % mod);
    const adds = [
      "+ export class TokenService {",
      "+ async refresh(token: string): Promise<Token> {",
      "+   if (isExpiring(token, SKEW_MS)) return this.reissue(token)",
      "+ const svc = new TokenService(secret, clock)",
      "+ router.use(withAuth(svc))",
      "+ return errorEnvelope(400, 'invalid_grant')",
      "+ export const SKEW_MS = 60_000",
    ];
    const dels = [
      "- const token = jwt.sign(payload, secret)",
      "- // TODO: pull this out of the handler",
      "- let cache: Record<string, Token> = {}",
      "- if (!req.headers.authorization) throw 401",
    ];
    const think = [
      "Mapping the call sites before touching anything.",
      "Safe to extract \u2014 no shared mutable state here.",
      "Two callers rely on the old signature; adding a shim.",
      "Rerunning the suite to confirm the fix.",
      "Cleaning up debug logging and stray comments.",
      "Keeping the diff small \u2014 rebasing onto main.",
      "Edge case: clock skew around expiry. Handling it.",
      "That branch wasn't covered; adding a test.",
    ];
    const c = [];
    const A = (t) => c.push({ k: "msg", who: "agent", text: t });
    const T = (t) => c.push({ k: "msg", who: "tool", text: t });
    const C = (t) => c.push({ k: "msg", who: "ci", text: t });
    const D = (file, add, del, line) => c.push({ k: "diff", file: file, add: add, del: del, line: line });
    A("Working on: " + f.title.toLowerCase() + ".");
    T("$ grep -rn \"" + sp(0) + "\" src/  \u2192  " + num(1, 6, 3) + " matches");
    A(think[i % think.length]);
    T("$ sed -n '1,40p' " + fp(0));
    A("Found " + sp(0) + " wired through " + fp(1) + "; isolating it first.");
    D(fp(0), num(2, 40, 8), num(3, 8, 0), adds[i % adds.length]);
    A("Extracted the core logic and tightened the types.");
    D(fp(1), num(4, 22, 4), num(5, 16, 3), dels[i % dels.length]);
    T("$ npx tsc --noEmit  \u2192  0 errors");
    A("Types are clean. Wiring the new service into the router.");
    D(fp(2), num(6, 14, 3), num(7, 4, 0), adds[(i + 2) % adds.length]);
    T("$ git add -p  \u00b7  staged " + num(8, 6, 2) + " hunks");
    A("Adding unit coverage for the refreshed path.");
    D(fp(5), num(9, 12, 6), 1, adds[(i + 4) % adds.length]);
    T("$ vitest run " + fp(5));
    C("\u2717 " + num(10, 30, 180) + " passed  \u00b7  " + (1 + i % 3) + " failed  (" + num(11, 9, 20) + "." + (i % 9) + "s)");
    A("A couple expiry cases failing \u2014 the clock mock wasn't frozen. Fixing.");
    D(fp(5), num(12, 10, 4), 2, "+ vi.setSystemTime(new Date('2026-01-01T00:00:00Z'))");
    T("$ vitest run " + fp(5));
    C("\u2713 " + num(13, 30, 200) + " passed  \u00b7  0 failed  (" + num(14, 9, 18) + "." + (i % 9) + "s)");
    A("Green. Removing the debug logs I added.");
    D(fp(0), 0, num(15, 6, 2), dels[(i + 1) % dels.length]);
    T("$ npm run lint  \u2192  0 problems");
    A("Committing this slice.");
    T("$ git commit  \u00b7  " + num(16, 5, 2) + " files changed, " + num(17, 60, 20) + " insertions(+)");
    let s = i * 9301 + 49297;
    const rnd = () => { s = (s * 9301 + 49297) % 233280; return s / 233280; };
    const rest = c.slice(1);
    for (let k = rest.length - 1; k > 0; k--) { const j = Math.floor(rnd() * (k + 1)); const tmp = rest[k]; rest[k] = rest[j]; rest[j] = tmp; }
    return [c[0]].concat(rest);
  }
  function sdRenderLogKeys(wrap) {
    if (!wrap) return;
    let html = "";
    for (let i = 0; i < 8; i++) {
      const idx = sdEventIdx + i;
      const ev = sdLog[idx];
      if (!ev) { html += '<button class="sd-key sd-empty" type="button" disabled aria-hidden="true"><span class="sd-key-face"></span></button>'; continue; }
      if (idx === 0) {
        html += '<button class="sd-key sd-live-key' + (sdSel === 0 ? ' sel' : '') + '" type="button" data-evidx="0"><span class="sd-key-face"><span class="sd-live"><span class="sd-live-title"><span class="sd-live-dot"></span>LIVE</span></span></span></button>';
        continue;
      }
      const dd = SD_LOG_DIR[ev.dir] || SD_LOG_DIR.info;
      html += '<button class="sd-key sd-log-key' + (idx === sdSel ? ' focus' : '') + '" type="button" data-evidx="' + idx + '">' +
        '<span class="sd-key-face"><span class="sd-log"><span class="sd-log-dir" style="color:' + dd.c + '">' + dd.l + '</span>' +
        '<span class="sd-log-text">' + esc(ev.text) + '</span>' +
        '<span class="sd-log-time">' + esc(ev.t) + '</span></span></span></button>';
    }
    wrap.innerHTML = html;
    wrap.querySelectorAll("[data-evidx]").forEach((b) => {
      b.addEventListener("click", () => {
        const idx = parseInt(b.dataset.evidx, 10);
        const maxC = sdChatMax();
        sdSel = idx; sdChatIdx = Math.min(sdEvStart[idx] || 0, maxC);
        sdKnobA = maxC > 0 ? ((maxC - sdChatIdx) / maxC) * 100 : 0; sdApplyRot(0, sdKnobA);
        sdRenderLogKeys(wrap); sdBuildLogStrip();
        const h = $("#sd-evhint"); if (h) h.innerHTML = sdEvHint();
      });
    });
  }
  function sdBuildFlat() {
    sdFlat = []; sdEvStart = [];
    for (let i = sdLog.length - 1; i >= 0; i--) {
      const ev = sdLog[i];
      sdEvStart[i] = sdFlat.length;
      sdFlat.push({ k: "evhdr", ev: i, text: ev.text, t: ev.t, dir: ev.dir });
      (ev.chat || []).forEach((c) => sdFlat.push(Object.assign({ ev: i }, c)));
    }
  }
  function sdChatMax() { return Math.max(0, sdFlat.length - 2); }
  function sdEnsureVisible() {
    const maxStart = Math.max(0, sdLog.length - 8);
    if (sdSel < sdEventIdx) sdEventIdx = sdSel;
    else if (sdSel > sdEventIdx + 7) sdEventIdx = Math.min(sdSel - 7, maxStart);
    sdEventIdx = Math.max(0, Math.min(sdEventIdx, maxStart));
  }
  function sdBackHint() {
    const older = sdChatIdx > 0;
    const newer = sdChatIdx < sdChatMax();
    return '<span class="sd-hint-ar" style="visibility:' + (older ? 'visible' : 'hidden') + '">\u2039</span>BACK<span class="sd-hint-ar" style="visibility:' + (newer ? 'visible' : 'hidden') + '">\u203a</span>';
  }
  function sdEvHint() {
    const canPrev = sdEventIdx > 0;
    const canNext = sdEventIdx < Math.max(0, sdLog.length - 8);
    return '<span class="sd-hint-ar" style="visibility:' + (canPrev ? 'visible' : 'hidden') + '">\u2039</span>EVENTS<span class="sd-hint-ar" style="visibility:' + (canNext ? 'visible' : 'hidden') + '">\u203a</span>';
  }
  function sdBuildLogStrip() {
    const screen = $("#sd-screen"); if (!screen) return;
    const whoC = { agent: "#9fd0ff", ci: "#88e0a6", tool: "#ffcf87", you: "#ffffff" };
    const len = sdFlat.length;
    let body = "";
    if (!len) body = '<div class="sd-chat-empty">No chat yet.</div>';
    else {
      for (let j = sdChatIdx; j < Math.min(len, sdChatIdx + 2); j++) {
        const c = sdFlat[j];
        if (c.k === "evhdr") {
          const dd = SD_LOG_DIR[c.dir] || SD_LOG_DIR.info;
          body += '<div class="sd-chat-ev"><span class="sd-chat-ev-dir" style="color:' + dd.c + '">' + dd.l + '</span><span class="sd-chat-ev-x">' + esc(c.text) + '</span><span class="sd-chat-ev-t">' + esc(c.t) + '</span></div>';
        } else if (c.k === "diff") {
          const cls = c.line && c.line[0] === "+" ? "add" : (c.line && c.line[0] === "-" ? "del" : "");
          body += '<div class="sd-chat-diff"><span class="sd-chat-file">' + esc(c.file) + ' <span class="add">+' + c.add + '</span> <span class="del">-' + c.del + '</span></span>' +
            (c.line ? '<code class="' + cls + '">' + esc(c.line) + '</code>' : '') + '</div>';
        } else {
          body += '<div class="sd-chat-msg"><span class="sd-chat-who" style="color:' + (whoC[c.who] || "#9fd0ff") + '">' + esc(c.who || "agent") + '</span>' + esc(c.text) + '</div>';
        }
      }
    }
    screen.innerHTML = '<div class="sd-log-page">' +
      '<div class="sd-chat-screen">' +
        '<div class="sd-chat-body">' + body + '</div>' +
      '</div>' +
      '<div class="sd-log-hints"><span class="sd-log-hint a" id="sd-backhint">' + sdBackHint() + '</span><span></span><span></span><span class="sd-log-hint d" id="sd-evhint">' + sdEvHint() + '</span></div>' +
    '</div>';
  }
  function sdEnterLogs() {
    sdMode = "logs"; sdLog = sdBuildLog(sdActive); sdBuildFlat(); sdEventIdx = 0; sdSel = 0; sdChatIdx = sdChatMax(); sdKnob3 = 0; sdKnobA = 0;
    sdApplyRot(3, 0); sdApplyRot(0, 0);
    sdRenderKeys(); sdBuildLogStrip();
  }
  function sdExitLogs() {
    if (sdLiveTimer) { clearInterval(sdLiveTimer); sdLiveTimer = null; }
    sdMode = "cmd"; sdRenderKeys(); sdBuildCmdStrip(sdActive);
  }
  function sdBack() {
    if (sdMode === "logs") { sdExitLogs(); }
    else if (sdMode === "cmd") { sdMode = "grid"; sdActive = null; sdBuildGridStrip(); sdRenderKeys(); sdRenderPager(); }
  }
  function sdRenderPager() {
    const d = $("#sd-seg-d"); if (!d) return;
    if (sdMode === "cmd" && sdActive) {
      d.querySelector(".sd-pg-dots").innerHTML = "";
      d.querySelector(".sd-seg-dlabel").textContent = "CONTROLLING";
      d.querySelector(".sd-pager-label").textContent = "AIUR-" + sdActive.num;
      return;
    }
    d.querySelector(".sd-seg-dlabel").textContent = "MORE AGENTS";
    const cur = sdCurWin();
    let dots = "";
    for (let p = 0; p < sdWindows; p++) dots += '<span class="sd-pg-dot' + (p === cur ? " on" : "") + '"></span>';
    d.querySelector(".sd-pg-dots").innerHTML = dots;
    d.querySelector(".sd-pager-label").textContent = "";
  }
  function initStreamdeck() {
    if (sdInit) return; sdInit = true;
    sdAgents = fleet
      .filter((f) => ["running", "alert", "paused", "stuck", "queued"].includes(bucketOf(f)))
      .sort((a, b) => {
        const ra = SD_RANK[sdStateOf(a)], rb = SD_RANK[sdStateOf(b)];
        if (ra !== rb) return ra - rb;
        if (ra === SD_RANK.queued) return (sdReady(b) ? 1 : 0) - (sdReady(a) ? 1 : 0);
        return 0;
      });
    sdMaxOff = Math.max(0, Math.ceil(sdAgents.length / 2) - 4);
    sdWindows = Math.max(1, Math.ceil(sdAgents.length / 8));

    sdBuildGridStrip();

    const knobs = $("#sd-knobs");
    for (let i = 0; i < 4; i++) {
      if (knobs) {
        const k = document.createElement("div");
        k.className = "sd-knob"; k.id = "sd-knob-" + i; k.tabIndex = 0;
        k.setAttribute("role", "slider"); k.setAttribute("aria-label", i === 3 ? "Dial D — turn or press to page agents" : "Dial " + "ABC"[i]);
        k.innerHTML = '<span class="sd-knob-dial"></span>';
        k.addEventListener("wheel", (e) => { e.preventDefault(); sdKnobDelta(i, -Math.sign(e.deltaY) * 4); }, { passive: false });
        let dragging = false, lastAng = 0, moved = 0;
        const angOf = (e) => { const r = k.getBoundingClientRect(); return Math.atan2(e.clientY - (r.top + r.height / 2), e.clientX - (r.left + r.width / 2)) * 180 / Math.PI; };
        k.addEventListener("pointerdown", (e) => { dragging = true; moved = 0; lastAng = angOf(e); try { k.setPointerCapture(e.pointerId); } catch (err) {} });
        k.addEventListener("pointermove", (e) => {
          if (!dragging) return;
          const a = angOf(e); let d = a - lastAng;
          if (d > 180) d -= 360; else if (d < -180) d += 360;
          lastAng = a; moved += Math.abs(d);
          sdKnobDelta(i, d / 2.7); // 270° sweep spans the full range
        });
        k.addEventListener("pointerup", () => {
          if (dragging && moved < 8) {
            k.classList.remove("press"); void k.offsetWidth; k.classList.add("press");
            setTimeout(() => k.classList.remove("press"), 160);
            if (i === 0) sdBack(); else if (i === 3) sdCycleWindow();
          }
          dragging = false;
        });
        k.addEventListener("keydown", (e) => {
          if (e.key === "ArrowUp" || e.key === "ArrowRight") { e.preventDefault(); sdKnobDelta(i, 4); }
          if (e.key === "ArrowDown" || e.key === "ArrowLeft") { e.preventDefault(); sdKnobDelta(i, -4); }
        });
        knobs.appendChild(k);
      }
    }
    const reset = $("#sd-reset");
    if (reset) reset.addEventListener("click", () => { for (let i = 0; i < 3; i++) sdSetDial(i, 0); sdResetView(); });
    for (let i = 0; i < 3; i++) sdApplyRot(i, 0);
    sdApplyRot(3, sdKnob3);
    sdRenderKeys();
    sdRenderPager();
  }

  function updateTabCounts() {
    const fc = $("#tabcount-inbox"); if (fc) fc.textContent = filterCount("open");
    const ff = $("#tabcount-fleet"); if (ff) ff.textContent = fleet.length;
  }
  function jumpToDecision(id) {
    const d = decisions.find((x) => x.id === id);
    if (!d) { toast("accent", "No open decision", id + " has no open decision right now."); return; }
    switchTab("inbox");
    activeFilter = "all";
    renderFilters();
    renderDecisions();
    setTimeout(() => {
      const card = findCardEl(id);
      if (card) {
        card.classList.add("open");
        window.scrollTo({ top: card.getBoundingClientRect().top + window.scrollY - 80, behavior: "smooth" });
        card.style.transition = "box-shadow .3s";
        card.style.boxShadow = "0 0 0 2px var(--accent)";
        setTimeout(() => (card.style.boxShadow = ""), 1400);
      }
    }, 40);
    location.hash = "d-" + id;
  }

  /* ============================================================
     TOAST + CONFIRM
     ============================================================ */
  function toast(tone, title, body) {
    const t = el("div", { class: "toast " + tone });
    const icon = tone === "good" ? ICON.checkCircle : tone === "block" ? ICON.warn : ICON.send;
    t.innerHTML = icon + "<div><b>" + esc(title) + '</b><span class="tmuted">' + esc(body) + "</span></div>";
    $("#toast-wrap").appendChild(t);
    setTimeout(() => { t.style.transition = "opacity .3s, transform .3s"; t.style.opacity = "0"; t.style.transform = "translateY(8px)"; setTimeout(() => t.remove(), 320); }, 4200);
  }

  let confirmCb = null;
  function confirmModal(title, body, okLabel, cb) {
    $("#confirm-title").textContent = title;
    $("#confirm-body").innerHTML = body;
    $("#confirm-ok").textContent = okLabel;
    confirmCb = cb;
    $("#confirm-modal").classList.add("show");
  }
  function closeConfirm() { $("#confirm-modal").classList.remove("show"); confirmCb = null; }

  /* ============================================================
     THEME + READ-ONLY
     ============================================================ */
  function applyTheme(theme) {
    document.documentElement.setAttribute("data-theme", theme);
    try { localStorage.setItem("aiur-theme", theme); } catch (e) {}
  }
  function initTheme() {
    let stored = null;
    try { stored = localStorage.getItem("aiur-theme"); } catch (e) {}
    const theme = stored || (window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");
    applyTheme(theme);
  }
  function setReadonly(on) {
    document.body.classList.toggle("readonly", on);
    $("#readonly-label").textContent = on ? "Read-only" : "Writable";
    $("#readonly-toggle").classList.toggle("is-on", on);
    try { localStorage.setItem("aiur-readonly", on ? "1" : "0"); } catch (e) {}
    // re-render decisions so action controls reflect mode
    renderDecisions();
    // reopen previously open cards? keep simple: leave collapsed
  }

  /* ============================================================
     CLOCK
     ============================================================ */
  function tickClock() {
    const c = $("#clock");
    if (!c) return;
    const d = new Date();
    const p = (n) => String(n).padStart(2, "0");
    c.textContent = p(d.getUTCHours()) + ":" + p(d.getUTCMinutes()) + ":" + p(d.getUTCSeconds()) + " UTC";
  }

  /* ============================================================
     INIT
     ============================================================ */
  function init() {
    initTheme();
    window.__aiurFleet = fleet;
    window.__aiurOpenTicket = function (id) { var f = fleet.find(function (x) { return x.id === id; }); if (f) openTicketModal(f); };

    renderOverview();
    renderBanner();
    renderFilters();
    renderDecisions();
    renderFleet();
    renderHistory();
    renderOutcomes();    updateTabCounts();

    // theme
    $("#theme-toggle").addEventListener("click", () => {
      const cur = document.documentElement.getAttribute("data-theme");
      applyTheme(cur === "light" ? "dark" : "light");
    });
    // confirm modal
    $("#confirm-cancel").addEventListener("click", closeConfirm);
    $("#confirm-modal").addEventListener("click", (e) => { if (e.target.id === "confirm-modal") closeConfirm(); });
    $("#confirm-ok").addEventListener("click", () => { const cb = confirmCb; closeConfirm(); if (cb) cb(); });

    // conversation drawer
    $("#conv-backdrop").addEventListener("click", (e) => { if (e.target.id === "conv-backdrop") closeConversation(); });
    // ticket context modal
    $("#tk-backdrop").addEventListener("click", (e) => { if (e.target.id === "tk-backdrop") closeTicketModal(); });
    const dback = $("#decisions-back"); if (dback) dback.addEventListener("click", () => switchTab("fleet"));
    document.addEventListener("keydown", (e) => { if (e.key === "Escape") { closeConversation(); closeTicketModal(); closeConfirm(); } });

    // decisions banner
    $("#decisions-banner").addEventListener("click", () => switchTab("inbox"));

    // sidebar nav
    $$(".snav").forEach((b) => b.addEventListener("click", () => switchTab(b.dataset.tab)));
    switchTab(activeTab);
    window.addEventListener("resize", () => { if (activeTab === "techtree") drawBoEdges(); });

    // clock
    tickClock();
    setInterval(tickClock, 1000);

    // deep-link on load
    if (location.hash && location.hash.startsWith("#d-")) {
      const id = location.hash.slice(3);
      setTimeout(() => jumpToDecision(id), 120);
    }
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();

</script>
</body>
</html>
