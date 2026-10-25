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
