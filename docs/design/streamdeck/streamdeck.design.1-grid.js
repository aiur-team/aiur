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
