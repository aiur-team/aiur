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
