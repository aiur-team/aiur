/* ============================================================
   AIUR — Build home page (Units + Build Order merged)
   Mock data, viewport-driven epic columns, timeline + Gantt.
   ============================================================ */
(function () {
  "use strict";
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const H = 36e5, DAY = 864e5;
  const NOW = new Date(2026, 9, 7, 14, 20).getTime();
  const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const WD = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const p2 = (n) => String(n).padStart(2, "0");
  const fmtD = (t) => { const d = new Date(t); return MON[d.getMonth()] + " " + d.getDate(); };
  const fmtWD = (t) => { const d = new Date(t); return WD[d.getDay()] + " " + MON[d.getMonth()] + " " + d.getDate(); };
  const fmtT = (t) => { const d = new Date(t); return p2(d.getHours()) + ":" + p2(d.getMinutes()); };
  const dayKey = (t) => { const d = new Date(t); return d.getFullYear() * 400 + d.getMonth() * 32 + d.getDate(); };
  const fmtH = (h) => h < 1 ? Math.max(5, Math.round(h * 60 / 5) * 5) + "m" : h < 10 ? (Math.round(h * 2) / 2) + "h" : Math.round(h) + "h";
  const fmtRange = (a, b) => {
    if (a == null) return "";
    const da = new Date(a), db = new Date(b);
    if (dayKey(a) === dayKey(b)) return fmtD(a);
    if (da.getMonth() === db.getMonth()) return MON[da.getMonth()] + " " + da.getDate() + "–" + db.getDate();
    return fmtD(a) + "–" + fmtD(b);
  };
  function rng(seed) { let s = seed >>> 0; return () => { s = (s + 0x6D2B79F5) >>> 0; let t = s; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
  function hash(s) { let h = 2166136261; for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619); return h >>> 0; }
  const pick = (r, a) => a[Math.floor(r() * a.length)];
  const pickW = (r, a, w) => { let x = r() * w.reduce((s, v) => s + v, 0); for (let i = 0; i < a.length; i++) { x -= w[i]; if (x <= 0) return a[i]; } return a[a.length - 1]; };

  const sv = (p, sw) => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="' + (sw || 2) + '" stroke-linecap="round" stroke-linejoin="round">' + p + "</svg>";
  const I = {
    bug: sv('<path d="M9 7.5V6a3 3 0 0 1 6 0v1.5"/><path d="M12 20c-3.3 0-6-2.7-6-6v-3a4 4 0 0 1 4-4h4a4 4 0 0 1 4 4v3c0 3.3-2.7 6-6 6z"/><path d="M12 20v-8M6 13H2.5M21.5 13H18M6.3 9 3.5 7.5M17.7 9l2.8-1.5M6.3 17.5 3.5 19M17.7 17.5l2.8 1.5"/>'),
    feature: sv('<path d="M21 8 12 3 3 8v8l9 5 9-5z"/><path d="m3 8 9 5 9-5M12 13v8"/>'),
    chore: sv('<path d="M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18l3 3 6.3-6.3a4 4 0 0 0 5.4-5.4l-2.6 2.6-2.4-.6-.6-2.4z"/>'),
    docs: sv('<path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20V3H6.5A2.5 2.5 0 0 0 4 5.5z"/><path d="M4 19.5A2.5 2.5 0 0 0 6.5 22H20v-5"/>'),
    pen: sv('<path d="m12 19 7-7 3 3-7 7z"/><path d="m18 13-1.5-7.5L2 2l3.5 14.5L13 18z"/><path d="m2 2 7.6 7.6"/><circle cx="11" cy="11" r="2"/>'),
    server: sv('<rect x="3" y="3" width="18" height="7" rx="2"/><rect x="3" y="14" width="18" height="7" rx="2"/><path d="M7 6.5h.01M7 17.5h.01"/>'),
    layers: sv('<path d="m12 2 10 5-10 5L2 7z"/><path d="m2 17 10 5 10-5M2 12l10 5 10-5"/>'),
    unsorted: sv('<rect x="4" y="4" width="16" height="16" rx="3" stroke-dasharray="3 3"/>'),
    lock: sv('<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>'),
    chev: sv('<path d="m6 9 6 6 6-6"/>', 2.4),
    x: sv('<path d="M18 6 6 18M6 6l12 12"/>', 2.4),
    filter: sv('<path d="M3 5h18l-7 8v6l-4 2v-8z"/>'),
    now: sv('<path d="M12 3v4M12 17v4"/><circle cx="12" cy="12" r="4"/><path d="M3 12h3M18 12h3"/>'),
    fit: sv('<path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/>'),
    graph: sv('<circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="8" r="3"/><path d="M6 9v6M18 11a9 9 0 0 1-9 9"/>'),
    gantt: sv('<path d="M3 4v16M7 6h6M10 11h9M7 16h7"/>'),
    focus: sv('<circle cx="12" cy="12" r="3"/><path d="M3 9V5a2 2 0 0 1 2-2h4M15 3h4a2 2 0 0 1 2 2v4M21 15v4a2 2 0 0 1-2 2h-4M9 21H5a2 2 0 0 1-2-2v-4"/>'),
    compact: sv('<path d="M4 6h16M4 12h16M4 18h16"/><path d="M9 3l3 3 3-3M9 21l3-3 3 3"/>'),
    warn: sv('<path d="M12 9v4M12 17h.01"/><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/>'),
    up: sv('<path d="M12 19V5M5 12l7-7 7 7"/>', 2.4),
    hourglass: sv('<path d="M6 2h12M6 22h12M7 2c0 6 10 6 10 10S7 16 7 22M17 2c0 6-10 6-10 10s10 4 10 10"/>'),
    pencil: sv('<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/>'),
    commit: sv('<circle cx="12" cy="12" r="3.5"/><path d="M3 12h5.5M15.5 12H21"/>'),
    pr: sv('<circle cx="6" cy="6" r="2.5"/><circle cx="6" cy="18" r="2.5"/><circle cx="18" cy="18" r="2.5"/><path d="M6 8.5v7M18 15.5V12a4 4 0 0 0-4-4h-3"/>'),
    merge: sv('<circle cx="6" cy="6" r="2.5"/><circle cx="6" cy="18" r="2.5"/><circle cx="18" cy="12" r="2.5"/><path d="M6 8.5v7M8.5 6a9 9 0 0 0 7 6"/>'),
    chat: sv('<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>'),
    link: sv('<path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/>'),
    ext: sv('<path d="M7 17 17 7M7 7h10v10"/>'),
    github: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2C6.48 2 2 6.58 2 12.26c0 4.5 2.87 8.32 6.84 9.67.5.1.68-.22.68-.49 0-.24-.01-.87-.01-1.71-2.78.62-3.37-1.37-3.37-1.37-.46-1.18-1.11-1.5-1.11-1.5-.91-.63.07-.62.07-.62 1 .07 1.53 1.05 1.53 1.05.9 1.57 2.35 1.12 2.92.85.09-.66.35-1.12.63-1.38-2.22-.26-4.55-1.14-4.55-5.05 0-1.12.39-2.03 1.03-2.75-.1-.26-.45-1.3.1-2.71 0 0 .84-.28 2.75 1.05a9.35 9.35 0 0 1 2.5-.34c.85 0 1.71.12 2.5.34 1.91-1.33 2.75-1.05 2.75-1.05.55 1.41.2 2.45.1 2.71.64.72 1.03 1.63 1.03 2.75 0 3.92-2.34 4.79-4.57 5.04.36.32.68.95.68 1.92 0 1.39-.01 2.51-.01 2.85 0 .27.18.6.69.49A10.02 10.02 0 0 0 22 12.26C22 6.58 17.52 2 12 2z"/></svg>',
    ticket: sv('<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6M8 13h8M8 17h5"/>'),
    tree: sv('<path d="M3 12h6"/><path d="M9 12c3.5 0 4.5-6 10-6M9 12c3.5 0 4.5 6 10 6"/><path d="m16 3.5 3 2.5-3 2.5M16 15.5l3 2.5-3 2.5"/>'),
    list: sv('<path d="M8 6h13M8 12h13M8 18h13M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>', 2.4),
    chevU: sv('<path d="m6 15 6-6 6 6"/>', 2.4),
    eye: sv('<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>'),
    cycle: sv('<path d="M20 11a8 8 0 0 0-14.8-3.5M4 13a8 8 0 0 0 14.8 3.5"/><path d="M4 3.5V8h4.5M20 20.5V16h-4.5"/>', 2.2),
    dId: sv('<path d="M4 6h16M4 10h16M4 14h16M4 18h16"/>'),
    dLine: sv('<rect x="3" y="4" width="18" height="6" rx="1.5"/><rect x="3" y="14" width="18" height="6" rx="1.5"/>'),
    dCard: sv('<rect x="3" y="3" width="8" height="18" rx="2"/><rect x="13" y="3" width="8" height="18" rx="2"/><path d="M6 7h2M16 7h2"/>'),
    bars: '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="4" width="4" height="16" rx="1"/><rect x="14" y="4" width="4" height="16" rx="1"/></svg>',
  };
  const GLYPH = {
    active: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>',
    error: sv('<path d="M12 5v8M12 18.5v.5"/>', 3.4),
    retries: sv('<path d="M20 12a8 8 0 1 1-2.3-5.7L20 8"/><path d="M20 3v5h-5"/>', 3),
    command: sv('<path d="M9 9a3 3 0 1 1 4.5 2.6c-.9.5-1.5 1.2-1.5 2.4M12 18.5v.5"/>', 3),
    paused: '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="5" width="4.2" height="14" rx="1"/><rect x="13.8" y="5" width="4.2" height="14" rx="1"/></svg>',
    parked: sv('<path d="M9 19V5h4.5a4 4 0 0 1 0 8H9"/>', 3.2),
  };
  const MODELS = {
    claude: { name: "Claude", full: "Claude Sonnet 4.5", logo: "assets/claude-symbol.svg" },
    codex: { name: "Codex", full: "GPT-5 Codex", logo: "assets/codex-color.svg" },
    deepseek: { name: "DeepSeek", full: "DeepSeek V3.2", logo: "assets/deepseek-logo.png", fill: true },
    kimi: { name: "Kimi", full: "Kimi K2", logo: "assets/kimi-logo.png", fill: true },
  };
  const AST = {
    active: { label: "Running", cls: "active" }, error: { label: "Error", cls: "stuck" }, retries: { label: "Retries exhausted", cls: "stuck" },
    command: { label: "Awaiting command", cls: "stuck" }, paused: { label: "Paused", cls: "idle" }, parked: { label: "Parked", cls: "idle" },
  };
  const CX = ["❶", "❷", "❸", "❹", "❺"];
  const PTS = [1, 2, 3, 5, 8];
  const EST = [1, 2, 4, 7, 11];
  /* proposal palette — general epics on 4 well-separated hues; features take the rest */
  const GENERAL = { bugs: { label: "Bugs", hue: 38, icon: "bug" }, design: { label: "Design", hue: 312, icon: "pen" }, infra: { label: "Infra", hue: 200, icon: "server" }, docs: { label: "Docs", hue: 100, icon: "docs" } };
  const POOL = {
    bugs: ["Flaky websocket reconnect", "Null deref in retry scheduler", "Race on concurrent ticket claims", "Wrong timezone in run summary", "Duplicate events after resume", "Leaked handles in log tailer", "Crash on empty PR body", "Stale token count after compaction", "Off-by-one in cursor math", "Memory growth in event stream", "Webhook signature mismatch", "Double-posted Khala messages"],
    design: ["Unit card density pass", "Command modal hierarchy", "Dark theme contrast audit", "Dependency edge legend", "Agent state glyph set", "Toolbar overflow on mobile", "First-run screens", "Empty states pass"],
    infra: ["Shard event log by repo", "Daemon heartbeat watchdog", "Rate-limit aware scheduler", "Cache GitHub API responses", "Structured logs to OTLP", "Blue/green daemon deploys", "Worker pool autoscaling", "Secrets rotation job", "Retry queue fsync path", "Queue snapshot compaction"],
    docs: ["Operator quickstart", "Commands lifecycle guide", "Events API reference", "Troubleshooting stuck agents", "Changelog for 0.8", "Architecture overview", "Contributor guide refresh"],
    unsorted: ["Investigate slow cold start", "Clarify ticket label rules", "Odd 502s from proxy", "Tidy feature flags", "Check flaky screenshot test"],
  };
  const FPOOL = {
    "f-khala-srv": ["Channel membership model", "Message fan-out worker", "Join request API", "Invite link tokens", "Agent listening modes", "History retention defaults", "Admin role checks", "Presence heartbeat"],
    "f-khala-ui": ["Roster panel", "Composer with mentions", "Invite popover", "Mode segmented control", "Join request card", "Channel settings popover", "Unread badges", "Mobile thread layout"],
    "f-pag-api": ["Cursor encoding for events", "Stable sort keys", "Page size limits", "Backward cursors", "Cursor expiry handling", "Index on (repo, ts)", "Per-page rate limits", "Pagination metrics"],
    "f-pag-ui": ["Paged events list", "Load-more affordance", "Scroll restoration", "Skeleton rows", "Jump to latest", "Filter + cursor reset", "Empty page state"],
    "f-docs": ["Docs theme + type", "MDX pipeline", "Search index", "Landing page", "Code sample tabs"],
  };

  /* ============================================================ DATA */
  function build(kind) {
    const r = rng(kind === "dense" ? 7 : 42);
    const epics = {}; Object.keys(GENERAL).forEach((k) => epics[k] = Object.assign({ key: k, general: true }, GENERAL[k]));
    epics.unsorted = { key: "unsorted", label: "Unsorted", hue: 0, icon: "unsorted", unsorted: true };
    const features = {};
    const addF = (k, label, hue, eps, a, b) => {
      features[k] = { key: k, label, hue, epics: eps.map((e) => e[0]), from: a, to: b };
      eps.forEach((e) => epics[e[0]] = { key: e[0], label: e[1], hue, icon: "layers", feature: k, temp: true });
    };
    if (kind === "dense") {
      const names = ["Auth v2", "Billing", "Search", "Mobile shell", "Audit log", "SSO", "Webhooks", "Exports", "Onboarding", "Notifications"];
      const hues = [175, 55, 285, 128, 232, 18, 330, 80, 250, 150];
      names.forEach((n, i) => {
        const a = new Date(2026, 3, 8).getTime() + i * 15 * DAY + r() * 3 * DAY, len = (12 + r() * 9) * DAY;
        const k = "d" + i, two = i % 3 !== 2;
        addF(k, n, hues[i], two ? [["f-" + k + "a", n + " · API"], ["f-" + k + "b", n + " · UI"]] : [["f-" + k + "a", n]], a, a + len);
      });
    }
    addF("khala", "Khala chat", 150, [["f-khala-srv", "Khala · server"], ["f-khala-ui", "Khala · client"]], new Date(2026, 8, 16).getTime(), new Date(2026, 8, 28, 22).getTime());
    addF("pag", "Events pagination", 272, [["f-pag-api", "Pagination · API"], ["f-pag-ui", "Pagination · UI"]], new Date(2026, 8, 29).getTime(), Infinity);
    const flist = Object.values(features);
    const featAt = (t) => flist.filter((f) => t >= f.from && t <= f.to);
    const epicAt = (t) => {
      const fs = featAt(t);
      if (fs.length && r() < 0.42) { const f = pick(r, fs); return pick(r, f.epics); }
      if (kind === "dense") { if (r() < 0.035) return null; return pickW(r, ["bugs", "design", "infra", "docs"], [0.34, 0.15, 0.33, 0.18]); }
      return pickW(r, ["bugs", "infra", "docs"], [0.4, 0.4, 0.2]);
    };

    /* history: simulate N agent slots working 09:00–22:30, idle weekends */
    let raw = [];
    if (kind !== "newrepo") {
      const from = kind === "dense" ? new Date(2026, 3, 6, 9).getTime() : new Date(2026, 8, 14, 9).getTime();
      const conc = kind === "dense" ? 6 : 4;
      const to = NOW - 0.4 * H;
      const nextMorning = (t) => { const d = new Date(t); d.setDate(d.getDate() + 1); d.setHours(9, Math.floor(r() * 40), 0, 0); return d.getTime(); };
      const work = (t) => {
        for (let k = 0; k < 12; k++) {
          const d = new Date(t), wd = d.getDay();
          if (wd === 0 || wd === 6) { t = nextMorning(t); continue; }
          const h = d.getHours() + d.getMinutes() / 60;
          if (h < 9) { d.setHours(9, Math.floor(r() * 40), 0, 0); return d.getTime(); }
          if (h >= 21.5) { t = nextMorning(t); continue; }
          return t;
        }
        return t;
      };
      const slots = Array.from({ length: conc }, (_, i) => from + i * 0.6 * H);
      for (let g = 0; g < 30000; g++) {
        let i = 0; for (let k = 1; k < slots.length; k++) if (slots[k] < slots[i]) i = k;
        if (slots[i] === Infinity) break;
        const st = work(slots[i] + r() * 0.5 * H);
        const cx = pickW(r, [1, 2, 3, 4, 5], [0.18, 0.3, 0.28, 0.16, 0.08]);
        const rg = [[0.4, 1.4], [1, 3], [2, 5.5], [4, 8.5], [7, 11.5]][cx - 1];
        const hrs = Math.max(0.25, (rg[0] + r() * (rg[1] - rg[0])) * (0.45 + r() * r() * 1.6));
        const en = st + hrs * H;
        const dEnd = new Date(st); dEnd.setHours(22, 30, 0, 0);
        if (en > to) { slots[i] = Infinity; continue; }
        if (en > dEnd.getTime()) { slots[i] = dEnd.getTime() + 60000; continue; }
        raw.push({ start: st, end: en, cx, epic: epicAt(st) });
        slots[i] = en + r() * 0.3 * H;
      }
      raw.sort((a, b) => a.start - b.start);
      if (kind === "dense") raw = raw.slice(-1300);
    }
    const all = [], byId = {};
    const add = (t) => { all.push(t); byId[t.id] = t; return t; };
    let num = kind === "dense" ? 1 : Math.max(1, 599 - raw.length);
    const hist = [];
    const lastBy = {};
    raw.forEach((x) => {
      const ep = x.epic, e = ep ? epics[ep] : null;
      const fs = featAt(x.start);
      const feature = e && e.feature ? e.feature : (fs.length && r() < 0.22 ? pick(r, fs).key : null);
      const type = !ep ? pick(r, ["bug", "chore", "feature"]) : ep === "bugs" ? "bug" : ep === "docs" ? "docs" : ep === "infra" ? (r() < 0.6 ? "chore" : "feature") : ep === "design" ? "feature" : (r() < 0.18 ? "bug" : (ep === "f-docs" ? "docs" : "feature"));
      const pool = FPOOL[ep] || POOL[ep || "unsorted"] || [e.label.split(" · ")[0] + " data model", e.label + " endpoints", e.label + " edge cases", e.label + " tests", e.label + " rollout flag", e.label + " metrics", e.label + " polish"];
      const also = !feature && fs.length && r() < 0.12 ? [pick(r, fs).key] : [];
      const t = add({ id: "AIUR-" + num, num: num++, title: pick(r, pool), type, epic: ep, feature, also, cx: x.cx, pts: PTS[x.cx - 1], sec: "hist", start: x.start, end: x.end, status: "done", pct: 100,
        agent: { model: pickW(r, ["claude", "codex", "deepseek", "kimi"], [0.42, 0.3, 0.14, 0.14]), state: null, effort: pick(r, ["low", "medium", "high"]) }, created: x.start - r() * 2.5 * DAY, deps: [] });
      const peers = hist.slice(-40).filter((p) => p.end < t.start && ((p.epic && p.epic === t.epic) || (p.feature && p.feature === t.feature)));
      if (peers.length && r() < 0.5) t.deps.push(pick(r, peers).id);
      if (peers.length > 2 && r() < 0.15) { const d = pick(r, peers).id; if (!t.deps.includes(d)) t.deps.push(d); }
      hist.push(t); lastBy[ep || "unsorted"] = t.id;
    });
    let failedId = null;
    for (let i = hist.length - 1; i >= 0; i--) if (hist[i].epic === "infra" && hist[i].end > NOW - 40 * H) { const f = hist[i]; f.status = "failed"; f.title = "Scheduler state snapshot format"; f.pct = 100; failedId = f.id; break; }
    const lastOk = (ep) => { for (let i = hist.length - 1; i >= 0; i--) if (hist[i].epic === ep && hist[i].status === "done") return hist[i].id; return null; };
    const keyId = {};
    const resolve = (k) => k === "FAIL" ? failedId : k.startsWith("H:") ? lastOk(k.slice(2)) : keyId[k];

    const ACTIVE = [
      ["a1", "Cursor-based events API", "f-pag-api", "pag", "feature", 4, "claude", "active", 64, 3.2, "high", ["H:f-pag-api"]],
      ["a2", "Virtualized paged list", "f-pag-ui", "pag", "feature", 3, "codex", "active", 38, 1.6, "medium", ["H:f-pag-ui"]],
      ["a3", "Persist retry state across restarts", "infra", null, "chore", 4, "claude", "command", 71, 5.1, "high", ["H:infra"], ["pag"]],
      ["a4", "Flaky websocket reconnect", "bugs", null, "bug", 2, "deepseek", "error", 22, 0.9, "medium", []],
      ["a5", "Rate-limit backoff ceiling", "infra", null, "chore", 2, "kimi", "retries", 45, 2.4, "low", []],
      ["a6", "Docs IA restructure", "docs", null, "docs", 3, "claude", "paused", 50, 4, "medium", []],
      ["a7", "Paged list empty states", "f-pag-ui", "pag", "feature", 2, "codex", "parked", 12, 6, "low", []],
      ["a8", "Stale cache on settings save", "bugs", null, "bug", 1, "kimi", "active", 80, 0.5, "low", []],
    ];
    const PLAN = [
      [1, "p1", "Cursor pagination for /tickets", "f-pag-api", "pag", "feature", 3, ["H:f-pag-api"], { promoted: "6m ago" }],
      [1, "p2", "Pagination controls component", "f-pag-ui", "pag", "feature", 2, ["H:f-pag-ui"]],
      [1, "p3", "Docs site nav + search", "docs", null, "docs", 3, []],
      [1, "p4", "Heartbeat watchdog alerts", "infra", null, "chore", 2, [], { held: "Held by Maya · release freeze until Thu" }],
      [1, "p5", "CI badge shows cached state", "bugs", null, "bug", 1, []],
      [2, "p6", "Backfill cursors for old events", "f-pag-api", "pag", "feature", 4, ["p1"], { added: 1 }],
      [2, "p7", "Keyboard nav in paged lists", "f-pag-ui", "pag", "feature", 2, ["p2"], { added: 1 }],
      [2, "p8", "Retry queue migration note", "docs", null, "docs", 1, ["a3"], { also: ["pag"] }],
      [2, "p9", "Restart-safe scheduler cutover", "infra", null, "chore", 5, ["H:infra", "a3"]],
      [2, "p10", "Versioned docs", "docs", null, "docs", 3, ["p3"]],
      [2, "p11", "Empty page illustrations", "f-pag-ui", "pag", "feature", 2, [], { override: { hours: 7, reason: "Planner override · needs 3 illustration rounds with design review — bumped from 2h to 7h" } }],
      [3, "p12", "Pagination e2e suite", "f-pag-api", "pag", "chore", 3, ["p6", "p7"], { added: 1 }],
      [3, "p13", "Persisted retry metrics", "infra", null, "feature", 3, ["p9"]],
      [3, "p14", "API reference for paging", "docs", null, "docs", 2, ["p6"], { also: ["pag"] }],
      [3, "p15", "Load test 10k-event pages", "f-pag-api", "pag", "chore", 4, ["p6"], { added: 1 }],
      [3, "p16", "Daemon restart runbook", "docs", null, "docs", 2, ["p9"]],
      [4, "p17", "Remove pagination flag", "f-pag-ui", "pag", "chore", 1, ["p12"], { added: 1 }],
      [4, "p18", "Docs site launch checklist", "docs", null, "docs", 2, ["p10", "p14"]],
      [4, "p19", "Drop legacy offset params", "f-pag-api", "pag", "chore", 2, ["p12", "p15"], { added: 1 }],
      [4, "p20", "Release notes 0.9", "docs", null, "docs", 1, ["p18"], { also: ["pag"] }],
    ];
    const DPOOL = { "f-dash-data": ["Normalize ticket events", "Project atom store", "Define wave selectors", "Join planning data", "Fetch build queue", "Persist layout prefs", "Migrate filters to URL", "Recover scroll anchor", "Enforce column order", "Usage snapshot feed"],
      "f-dash-ui": ["Render wave lanes", "Adapt ticket squares", "Resolve epic palette", "Ship gantt axis", "Harden graph edges", "Integrate usage cards", "Vendor layout engine", "Project mobile grid", "Render now band", "Align feature header"] };
    const TARGET = [8, 10, 11, 9, 7, 9];
    const defs = PLAN.slice();
    for (let w = 1; w <= 6; w++) {
      const have = defs.filter((p) => p[0] === w).length;
      for (let j = 0; j < TARGET[w - 1] - have; j++) {
        const ep = pickW(r, ["f-pag-api", "f-pag-ui", "bugs", "infra", "docs"], [0.3, 0.3, 0.14, 0.16, 0.1]);
        const e = ep ? epics[ep] : null, cx = pickW(r, [1, 2, 3, 4, 5], [0.3, 0.32, 0.22, 0.1, 0.06]);
        const prev = defs.filter((p) => p[0] === w - 1 || (p[0] === w - 2 && r() < 0.3));
        const deps = [];
        if (prev.length) { const same = prev.filter((p) => p[3] === ep || (e && e.feature && p[4] === e.feature)); const n = 1 + Math.floor(r() * 2.6); for (let q = 0; q < n; q++) { const c = same.length && r() < 0.6 ? pick(r, same) : pick(r, prev); if (!deps.includes(c[1])) deps.push(c[1]); } }
        defs.push([w, "x" + w + "_" + j, pick(r, DPOOL[ep] || FPOOL[ep] || POOL[ep || "unsorted"]), ep, e && e.feature ? e.feature : null, ep === "bugs" || !ep ? "bug" : ep === "docs" || ep === "f-docs" ? "docs" : r() < 0.3 ? "chore" : "feature", cx, deps, e && e.feature === "pag" ? { added: 1 } : null]);
      }
    }
    defs.sort((a, b) => a[0] - b[0]);
    let act = ACTIVE;
    if (kind === "newrepo") act = ACTIVE.filter((a) => ["a1", "a2", "a4", "a8"].includes(a[0]));
    const now = act.map((a) => {
      const t = add({ id: "AIUR-" + num, num: num++, title: a[1], epic: a[2], feature: a[3], type: a[4], cx: a[5], pts: PTS[a[5] - 1], also: a[12] || [], sec: "now",
        agent: { model: a[6], state: a[7], effort: a[10] }, pct: a[8], est: Math.max(a[9] + 0.5, Math.round(a[9] / Math.max(0.15, a[8] / 100) * (0.8 + r() * 0.5) * 4) / 4), start: NOW - a[9] * H, created: NOW - (a[9] + 20) * H, depKeys: a[11], deps: [], status: "running" });
      keyId[a[0]] = t.id; return t;
    });
    const plan = kind === "noqueue" ? [] : defs.map((p, i) => {
      const x = p[8] || {};
      const t = add({ id: "AIUR-" + num, num: num++, title: p[2], epic: p[3], feature: p[4], type: p[5], cx: p[6], pts: PTS[p[6] - 1], also: x.also || [], sec: "plan", wave: p[0], qpos: i + 1,
        est: Math.max(0.5, Math.round(EST[p[6] - 1] * (0.35 + r() * 1.5) * 4) / 4), override: x.override || null, added: !!x.added, depKeys: p[7], deps: [], status: "queued", pct: 0, created: x.added ? new Date(2026, 9, 4).getTime() + r() * 3 * DAY : NOW - (6 + r() * 10) * DAY, cue: { held: x.held || null, promoted: x.promoted || null } });
      keyId[p[1]] = t.id; return t;
    });
    [...now, ...plan].forEach((t) => { t.deps = t.depKeys.map(resolve).filter(Boolean); delete t.depKeys; });
    /* not queued */
    const nq = [];
    const nqN = kind === "newrepo" ? 6 : 22;
    for (let i = 0; i < nqN; i++) {
      const ep = pickW(r, ["bugs", "infra", "docs", "f-pag-ui", "f-pag-api"], [0.3, 0.24, 0.16, 0.15, 0.15]);
      const e = ep ? epics[ep] : null;
      const cx = pickW(r, [1, 2, 3, 4], [0.3, 0.35, 0.25, 0.1]);
      const feature = e && e.feature ? e.feature : null;
      nq.push(add({ id: "AIUR-" + num, num: num++, title: pick(r, FPOOL[ep] || POOL[ep || "unsorted"]), epic: ep, feature, type: ep === "bugs" || !ep ? "bug" : ep === "docs" || ep === "f-docs" ? "docs" : "feature",
        cx, pts: PTS[cx - 1], also: [], sec: "nq", status: "open", pct: 0, deps: [], added: feature === "pag", created: feature === "pag" ? new Date(2026, 9, 5).getTime() + r() * 2 * DAY : NOW - r() * 20 * DAY }));
    }
    all.forEach((t) => { if (t.feature === "pag" && t.sec === "hist") t.added = t.created > new Date(2026, 9, 3).getTime(); });
    /* cues */
    const failedDeps = new Set();
    if (failedId) { const walk = (id) => plan.forEach((p) => { if (p.deps.includes(id) && !failedDeps.has(p.id)) { failedDeps.add(p.id); walk(p.id); } }); walk(failedId); }
    plan.forEach((p) => {
      const open = p.deps.map((d) => byId[d]).filter((d) => d && d.status !== "done");
      p.cue.failed = null;
      const live = open.filter((d) => d.sec === "now");
      p.cue.wait = !p.cue.failed && live.length ? live[0].num : null;
      p.cue.waitAny = open.length > 0;
      p.cue.blockedChain = false;
    });
    const children = {}; all.forEach((t) => t.deps.forEach((d) => (children[d] = children[d] || []).push(t.id)));
    /* epic order: general, features by start, unsorted */
    const order = ["bugs", "design", "infra", "docs"];
    flist.slice().sort((a, b) => a.from - b.from).forEach((f) => f.epics.forEach((e) => order.push(e)));
    order.push("unsorted");
    const counts = {}; all.forEach((t) => { const k = t.epic || "unsorted"; counts[k] = (counts[k] || 0) + 1; });
    return { kind, epics, features, order, all, byId, hist, now, plan, nq, children, counts, failedId };
  }
  const cache = {};
  const dataFor = (demo) => { const k = demo === "dense" ? "dense" : demo === "newrepo" ? "newrepo" : demo === "noqueue" ? "noqueue" : "live"; return cache[k] || (cache[k] = build(k)); };

  /* ============================================================ STATE + URL */
  const FKEYS = ["epic", "feature", "model", "tstate", "astate"];
  const epicOk = (t) => !S.f.epic.length || S.f.epic.includes(colKey(t));
  const SPANS = [1, 2, 3, 5, 7, 10, 14, 21, 30];
  const S = { view: "graph", span: 1, feature: null, fmode: "focus", f: { type: [], model: [], feature: [], epic: [], tstate: [], astate: [] }, demo: "live", pop: null, loading: true, flow: false, K: 2, density: "card", trees: false, models: 4, liveMin: false };
  function readURL() {
    const p = new URLSearchParams(location.search);
    if (["gantt", "list"].includes(p.get("view"))) S.view = p.get("view");
    if (p.get("trees") === "1") S.trees = true;
    if (["2", "7"].includes(p.get("models"))) S.models = +p.get("models");
    if (p.get("live") === "min") S.liveMin = true;
    const sp = +p.get("span"); if (SPANS.includes(sp)) S.span = sp;
    if (p.get("feature")) S.feature = p.get("feature");
    if (p.get("fmode") === "compact") S.fmode = "compact";
    FKEYS.forEach((k) => { const v = p.get(k); if (v && k !== "feature") S.f[k] = v.split(","); });
    if (p.get("example")) S.demo = p.get("example");
  }
  function writeURL(extra) {
    const p = new URLSearchParams(location.search);
    const set = (k, v) => v ? p.set(k, v) : p.delete(k);
    set("view", S.view !== "graph" ? S.view : ""); set("trees", S.trees ? "1" : ""); set("models", S.models !== 4 ? String(S.models) : ""); set("live", S.liveMin ? "min" : "");
    set("span", S.span !== 1 ? String(S.span) : ""); p.delete("zoom");
    p.delete("density");
    set("feature", S.feature || ""); set("fmode", S.feature && S.fmode === "compact" ? "compact" : "");
    FKEYS.forEach((k) => { if (k !== "feature") set(k, S.f[k].join(",")); });
    set("example", S.demo !== "live" ? S.demo : "");
    if (extra) Object.keys(extra).forEach((k) => set(k, extra[k]));
    const q = p.toString();
    history.replaceState(null, "", location.pathname + (q ? "?" + q.replace(/%2C/g, ",") : "") + location.hash);
  }

  /* ============================================================ DERIVED */
  let D = null, L = null;
  const colKey = (t) => t.epic || "unsorted";
  const tstate = (t) => t.sec === "hist" ? (t.status === "failed" ? "failed" : "merged") : t.sec === "now" ? "in progress" : t.sec === "plan" ? (t.cue.held ? "held" : (t.cue.waitAny || t.cue.failed || t.cue.blockedChain) ? "blocked" : "queued") : "open";
  const astate = (t) => t.sec === "now" ? t.agent.state : "none";
  function match(t) {
    for (const k of FKEYS) {
      const sel = S.f[k]; if (!sel.length) continue;
      const v = k === "type" ? t.type : k === "model" ? (t.agent ? t.agent.model : "none") : k === "feature" ? t.feature : k === "epic" ? colKey(t) : k === "tstate" ? tstate(t) : astate(t);
      if (Array.isArray(v) ? !v.some((x) => sel.includes(x)) : !sel.includes(v)) return false;
    }
    return true;
  }
  function featStats(fk) {
    const ts = D.all.filter((t) => t.feature === fk);
    const done = ts.filter((t) => t.sec === "hist" && t.status === "done").length;
    let wp = 0, w = 0; ts.forEach((t) => { w += t.pts; wp += t.pts * (t.sec === "hist" ? 1 : t.sec === "now" ? t.pct / 100 : 0); });
    const added = ts.filter((t) => t.added).length;
    const first = Math.min(...ts.map((t) => t.created)), days = [];
    for (let d = first; d <= NOW + 1; d += DAY) days.push(ts.filter((t) => t.created <= d).length);
    if (days[days.length - 1] !== ts.length) days.push(ts.length);
    return { total: ts.length, done, pct: w ? Math.round(wp / w * 100) : 0, orig: ts.length - added, added, spark: days, also: D.all.filter((t) => t.also.includes(fk)).length };
  }

  /* ============================================================ LAYOUT */
  const LH = 46, SEC = 36;
  function computeLayout() {
    const NOWL = D.now.filter(epicOk), PLANL = D.plan.filter(epicOk), NQL = D.nq.filter(epicOk);
    const span = S.span || 1, fs = 13, flow = S.flow, K = S.K, vh = Math.max(300, (vp ? vp.clientHeight : 700) - LH - 40);
    let gap = 14;
    const pphG = span <= 1 ? 18 : Math.max(0.45, vh / (span * 11));
    const dayL = (t) => flow ? fmtD(t) : fmtWD(t);
    const baseDet = "full";
    let det = baseDet;
    const CH = { full: 9.4 * fs, line: 2.5 * fs, mini: Math.max(24, 2.3 * fs) };
    let ch = CH[det], pitch = ch + gap;
    const F = S.feature, compact = !!(F && S.fmode === "compact");
    const inF = (t) => t.feature === F || t.also.includes(F);
    const ghost = new Set();
    if (compact) D.all.filter(inF).forEach((t) => t.deps.forEach((d) => { const x = D.byId[d]; if (x && !inF(x)) ghost.add(d); }));
    const entries = (list) => {
      if (!compact) return list.map((t) => ({ t }));
      const out = []; let g = null;
      list.forEach((t) => {
        if (inF(t) || ghost.has(t.id)) { if (g) { out.push({ gap: g }); g = null; } out.push({ t, ghost: !inF(t) }); }
        else { if (!g) g = { n: 0, a: t.end || null, b: t.end || null }; g.n++; if (t.end) g.b = t.end; }
      });
      if (g) out.push({ gap: g });
      return out;
    };
    const gapLabel = (g) => "+" + g.n + " unrelated" + (g.a ? " · " + fmtRange(g.a, g.b) : "");
    const histList = D.hist.filter((t) => t.end >= (S.histFrom || 0) && epicOk(t)).sort((a, b) => a.end - b.end);
    if (span > 1 && S.view !== "gantt") {
      const ds = histDays(), from = ds.length ? ds[Math.max(0, ds.length - span)] : 0;
      let n = 0, cur = null;
      entries(histList.filter((t) => t.end >= from)).forEach((e) => { if (e.gap) { n++; cur = null; return; } const k = flow ? null : colKey(e.t); if (!cur || (flow ? cur.size >= K : cur.has(k))) { n++; cur = new Set(); } cur.add(flow ? cur.size : k); });
      const target = vh / Math.max(1, n);
      gap = Math.max(2, Math.min(14, target * 0.18));
      ch = Math.min(CH[baseDet], Math.max(5, target - gap));
      const TI = ["bar", "mini", "line", "full"], bi = ch >= CH.full ? 3 : ch >= CH.line ? 2 : ch >= 22 ? 1 : 0;
      det = TI[Math.min(bi, TI.indexOf(baseDet))];
      pitch = ch + gap;
    }
    function rows(ents, y, items, marks, labels, sec, timeLabels) {
      let cur = null, lastDay = null;
      const flush = () => {
        if (!cur || !cur.size) { cur = null; return; }
        let first = null;
        cur.forEach((e, k) => { items.push({ t: e.t, ghost: e.ghost, key: k, y, h: ch, sec }); if (!first || e.t.end < first.end) first = e.t; });
        if (timeLabels && first.end) {
          const dk = dayKey(first.end);
          if (dk !== lastDay) { labels.push({ y, day: fmtD(first.end), t: WD[new Date(first.end).getDay()], line: lastDay != null }); lastDay = dk; }
        }
        y += pitch; cur = null;
      };
      ents.forEach((e) => {
        if (e.gap) { flush(); marks.push({ kind: "gap", y, h: 26, label: gapLabel(e.gap) }); y += 26 + gap; return; }
        if (flow) { if (cur && cur.size >= K) flush(); if (!cur) cur = new Map(); cur.set("s" + cur.size, e); return; }
        const k = colKey(e.t);
        if (cur && cur.has(k)) flush();
        if (!cur) cur = new Map();
        cur.set(k, e);
      });
      flush();
      return y;
    }
    const out = { det, base: baseDet, fs, ch, pitch, gap, secs: {} };
    /* history */
    const hs = { items: [], marks: [], labels: [], h: 0 };
    if (!histList.length) { hs.marks.push({ kind: "empty", y: SEC, h: 96, label: "No history yet", sub: "A new repo — nothing has merged. The first tickets are running in the Now band below." }); hs.h = SEC + 104; }
    else if (S.view === "gantt") ganttHist(entries(histList), hs);
    else hs.h = rows(entries(histList), SEC + 4, hs.items, hs.marks, hs.labels, "hist", true) + gap;
    out.secs.hist = hs;
    /* gantt helper */
    function ganttHist(ents, o) {
      const pph = pphG, BRK = span <= 1 ? 30 : Math.max(4, Math.round(30 / Math.sqrt(span))), ivs = [];
      ents.forEach((e) => { if (e.t) ivs.push([e.t.start, e.t.end]); });
      NOWL.forEach((t) => ivs.push([t.start, NOW]));
      ivs.sort((a, b) => a[0] - b[0]);
      const merged = [];
      ivs.forEach((iv) => { const l = merged[merged.length - 1]; if (l && iv[0] <= l[1]) l[1] = Math.max(l[1], iv[1]); else merged.push(iv.slice()); });
      const segs = []; let y = SEC + 12, cur = merged[0][0];
      const lin = (a, b) => { if (b <= a) return; const h = (b - a) / H * pph; segs.push({ t0: a, t1: b, y0: y, y1: y + h }); y += h; };
      const brk = (a, b) => { segs.push({ t0: a, t1: b, y0: y, y1: y + BRK, br: true }); y += BRK; };
      merged.forEach((m) => { if (m[0] - cur > 3 * H) brk(cur, m[0]); else lin(cur, m[0]); lin(Math.max(cur, m[0]), m[1]); cur = Math.max(cur, m[1]); });
      if (NOW - cur > 3 * H) brk(cur, NOW); else lin(cur, NOW);
      const tY = (t) => {
        let lo = 0, hi = segs.length - 1;
        while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (segs[mid].t0 <= t) lo = mid; else hi = mid - 1; }
        const s = segs[lo]; if (!s) return y;
        return s.y0 + Math.min(1, Math.max(0, (t - s.t0) / ((s.t1 - s.t0) || 1))) * (s.y1 - s.y0);
      };
      ents.forEach((e) => { if (!e.t) return; const a = tY(e.t.start), b = tY(e.t.end); o.items.push({ t: e.t, ghost: e.ghost, key: flow ? "g" : colKey(e.t), y: a, h: Math.max(b - a - 1, span <= 2 ? CH.mini : 4), sec: "hist" }); });
      assignLanes(o.items);
      const gaps = ents.filter((e) => e.gap).map((e) => e.gap);
      let prevB = -Infinity;
      segs.forEach((s) => {
        if (!s.br) return;
        const hrs = (s.t1 - s.t0) / H;
        let label = hrs >= 20 ? "Idle · " + fmtWD(s.t0) + " " + fmtT(s.t0) + " → " + fmtWD(s.t1) + " " + fmtT(s.t1) + " · " + Math.round(hrs) + "h" : "";
        if (compact) { const gs = gaps.filter((g) => g.b > prevB && g.b <= s.t1); const n = gs.reduce((a, g) => a + g.n, 0); if (n) label = "+" + n + " unrelated · " + fmtRange(gs[0].a, gs[gs.length - 1].b) + (label ? " · " + label : ""); }
        prevB = s.t1;
        o.marks.push({ kind: "brk", y: s.y0, h: BRK, label });
      });
      const step = [1, 2, 3, 6, 12, 24].find((s) => s * pph >= 30) || 24;
      let lastDay = null;
      segs.forEach((s) => {
        if (s.br) return;
        const d = new Date(s.t0); d.setMinutes(0, 0, 0);
        if (d.getTime() < s.t0) d.setHours(d.getHours() + 1);
        for (let k = 0; k < 400 && d.getTime() <= s.t1; k++) {
          if (d.getHours() % step === 0) {
            const t = d.getTime(), dk = dayKey(t);
            if (dk !== lastDay) { o.labels.push({ y: tY(t), day: dayL(t), t: fmtT(t), line: lastDay != null }); lastDay = dk; }
            else o.labels.push({ y: tY(t), t: fmtT(t), tick: true });
          }
          d.setHours(d.getHours() + 1);
        }
      });
      o.h = y + 10;
    }
    function assignLanes(items) {
      const by = {};
      items.forEach((it) => (by[it.key] = by[it.key] || []).push(it));
      Object.values(by).forEach((list) => {
        list.sort((a, b) => a.y - b.y);
        let cl = [], end = -1, lanes = [];
        const fin = () => cl.forEach((it) => it.lanes = lanes.length);
        list.forEach((it) => {
          if (it.y >= end) { fin(); cl = []; lanes = []; }
          let li = lanes.findIndex((e) => e <= it.y); if (li < 0) { li = lanes.length; lanes.push(0); }
          lanes[li] = it.y + it.h + 2; it.lane = li; cl.push(it); end = Math.max(end, it.y + it.h + 2);
        });
        fin();
      });
    }
    /* now band */
    const band = { items: [], h: 0 };
    const stack = {}, BH = 42;
    const gv = S.view === "gantt";
    const BL = D.now.slice().sort((a, b) => D.order.indexOf(colKey(a)) - D.order.indexOf(colKey(b)) || a.num - b.num);
    const BK = Math.max(1, Math.min(BL.length || 1, Math.floor(((vp ? vp.clientWidth : 1000) - (root && root.clientWidth < 640 ? 46 : 84) - 14) / 230)));
    band.BK = BK;
    if (!S.liveMin) BL.forEach((t, n) => { const k = "b" + (n % BK); const y0 = stack[k] != null ? stack[k] : BH; const h = gv ? Math.max(Math.min(14 * pphG, t.est * pphG), CH.line + Math.min(48, t.est * 3.2)) : (span > 1 ? Math.min(CH[baseDet], Math.max(ch, CH.line)) : ch); band.items.push({ t, key: k, y: y0, h, sec: "now", gt: true }); stack[k] = y0 + h + gap; });
    const maxY = Math.max(0, ...Object.values(stack));
    band.h = S.liveMin ? 38 : maxY ? maxY + 12 - gap : BH + 44;
    out.band = band;
    /* planned */
    const ps = { items: [], marks: [], labels: [], h: 0 };
    if (!PLANL.length) { ps.marks.push({ kind: "empty", y: SEC, h: 96, label: "Nothing planned", sub: "The build queue is empty. " + NQL.length + " open tickets are not queued — promote some to keep agents busy." }); ps.h = SEC + 104; }
    else {
      let y = SEC + 4, cum = 0;
      const pph = pphG;
      [...new Set(PLANL.map((t) => t.wave))].sort((a, b) => a - b).forEach((w) => {
        const list = PLANL.filter((t) => t.wave === w); if (!list.length) return;
        const ents = entries(list);
        if (compact && !ents.some((e) => e.t)) { ps.marks.push({ kind: "gap", y, h: 26, label: "W" + w + " · " + gapLabel(ents[0].gap) }); y += 26 + gap; return; }
        y += gap * 0.6;
        ps.labels.push({ y, day: "W" + w, t: list.length + (w === 1 ? " · ready" : ""), tk: true, line: w > 1, wave: true });
        if (S.view === "gantt") {
          const start = y, cur = {}; let end = start;
          ents.forEach((e) => {
            if (e.gap) return;
            let k;
            if (flow) { k = "s0"; for (let i = 1; i < K; i++) { const kk = "s" + i; if ((cur[kk] != null ? cur[kk] : start) < (cur[k] != null ? cur[k] : start)) k = kk; } } else k = colKey(e.t);
            const yy = cur[k] != null ? cur[k] : start;
            const hrs = e.t.override ? e.t.override.hours : e.t.est;
            const h = Math.max(hrs * pph, span > 2 ? 4 : det === "mini" ? CH.mini : CH.line);
            ps.items.push({ t: e.t, ghost: e.ghost, key: k, y: yy, h, sec: "plan", gantt: true });
            cur[k] = yy + h + gap * 0.5; end = Math.max(end, cur[k]);
          });
          ps.labels.push({ y: start + 30, t: "≈ +" + Math.round(cum) + "h" });
          cum += (end - start) / pph;
          y = end + gap * 0.5;
        } else y = rows(ents, y, ps.items, ps.marks, ps.labels, "plan", false);
      });
      ps.h = y + gap;
    }
    out.secs.plan = ps;
    /* not queued */
    const ns = { items: [], marks: [], labels: [], h: 0 };
    ns.h = rows(entries(NQL), SEC + 4, ns.items, ns.marks, ns.labels, "nq", false) + gap;
    out.secs.nq = ns;
    return out;
  }

  /* ============================================================ DOM */
  let root, vp, content, lanesEl, guidesEl, svg, bandEl, secs = {};
  const R = new Map(), RL = new Map(), laneEls = new Map(), guideEls = new Map();
  let cols = [], colMap = {}, bandMap = {}, colTimer = null, edgeTimer = null, raf = 0, inited = false, hoverId = null, loadingTimer = null;
  const rmOn = () => window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches;
  const gutW = () => (root.clientWidth < 640 ? 46 : 84);

  function shell() {
    root = $("#build-root");
    root.innerHTML =
      '<div id="bd-usage"></div>' +
      '<div id="bd-offline"></div>' +
      '<div id="bd-fh"></div>' +
      '<div class="bd-toolbar"><div class="bd-bar-l" id="bd-tools-l"></div><div class="bd-filters" id="bd-filters"></div><div class="bd-bar-r" id="bd-tools"></div></div>' +
      '<div class="bd-vpw"><div class="bd-vp" id="bd-vp"></div><div class="bd-sb" id="bd-sb"><i></i></div><div class="bd-tree" id="bd-tree" hidden></div></div>' +
      '<div class="bd-status" id="bd-status"></div>';
    vp = $("#bd-vp");
    const sb = $("#bd-sb"), th = $("i", sb);
    const syncSB = () => { const sh = vp.scrollHeight, chh = vp.clientHeight; if (sh <= chh + 1) { sb.classList.add("off"); return; } sb.classList.remove("off"); const tr = sb.clientHeight, h = Math.max(28, tr * chh / sh); th.style.height = h + "px"; th.style.transform = "translateY(" + (Math.min(1, vp.scrollTop / (sh - chh)) * (tr - h)) + "px)"; };
    vp.addEventListener("scroll", () => { syncSB(); sb.classList.add("act"); clearTimeout(sb._t); sb._t = setTimeout(() => sb.classList.remove("act"), 700); }, { passive: true });
    new ResizeObserver(syncSB).observe(vp); setInterval(syncSB, 500);
    th.addEventListener("pointerdown", (e) => { e.preventDefault(); th.setPointerCapture(e.pointerId); const y0 = e.clientY, s0 = vp.scrollTop, k = (vp.scrollHeight - vp.clientHeight) / Math.max(1, sb.clientHeight - th.offsetHeight); sb.classList.add("drag");
      const mv = (ev) => { vp.scrollTop = s0 + (ev.clientY - y0) * k; }; const up = () => { sb.classList.remove("drag"); th.removeEventListener("pointermove", mv); th.removeEventListener("pointerup", up); }; th.addEventListener("pointermove", mv); th.addEventListener("pointerup", up); });
    sb.addEventListener("pointerdown", (e) => { if (e.target !== sb) return; const r = sb.getBoundingClientRect(); vp.scrollTop = (e.clientY - r.top) / r.height * (vp.scrollHeight - vp.clientHeight); });
    root.classList.toggle("rm", rmOn());
    document.addEventListener("click", (e) => {
      if (!lockId || !e.target.isConnected || e.target.closest(".bd-lt, .bd-tree, .bd-eh, #tk-backdrop")) return;
      const c = e.target.closest(".bd-card"); if (c && chainOf(lockId).has(c.dataset.id)) return;
      unlock();
    });
    document.addEventListener("keydown", (e) => { if (e.key !== "Escape") return; if (!$("#bd-tree").hidden) closeTree(); else if (lockId) unlock(); });
    vp.addEventListener("scroll", () => { liveGuard(); markScrolling(); if (!raf) raf = requestAnimationFrame(() => { raf = 0; update(); }); }, { passive: true });
    let lastST = -1;
    setInterval(() => { if (!vp || S.loading || !L || !isVisible()) return; if (vp.scrollTop !== lastST) { lastST = vp.scrollTop; update(); } }, 250);
    document.addEventListener("click", (e) => { if (S.pop && !e.target.closest(".bd-pop") && !e.target.closest(".bd-fg")) { S.pop = null; renderFilters(); } });
    let rz = 0;
    window.addEventListener("resize", () => { clearTimeout(rz); rz = setTimeout(() => { if (inited && isVisible() && !S.loading) { const f = vp.scrollTop / Math.max(1, vp.scrollHeight); relayout(); vp.scrollTop = f * vp.scrollHeight; update(); } }, 140); });
  }
  let scrolling = false, scrollTimer = 0;
  function markScrolling() {
    if (!scrolling) { scrolling = true; if (content) content.classList.add("scrolling"); if (hoverId && !lockId) setHover(null); }
    clearTimeout(scrollTimer);
    scrollTimer = setTimeout(() => { scrolling = false; if (content) content.classList.remove("scrolling"); snapLive(); }, 200);
  }
  const isVisible = () => root && root.offsetParent !== null;
  /* Live never parks mid-screen: once scrolling settles it glides to the top (future view) or the bottom (history view) */
  let snapping = false, lastSnapST = 0;
  function liveGuard() {
    if (snapping || !L || !content || S.view === "list" || S.loading || paging) { lastSnapST = vp ? vp.scrollTop : 0; return; }
    if (document.querySelector(".bd-sb.drag")) return;
    const st = vp.scrollTop, dir = st - lastSnapST; lastSnapST = st;
    const nat = secs.hist.el.offsetTop + L.secs.hist.h, y = nat - st, vh = vp.clientHeight, bh = L.band.h, topY = LH, botY = vh - bh, T = 36;
    if (botY <= topY + T * 2) return;
    if (dir < 0 && y > topY + T && y < botY) { snapping = true; scrollVP(nat + bh - vh, true); setTimeout(() => { snapping = false; lastSnapST = vp.scrollTop; }, 460); }
    else if (dir > 0 && y < botY - T && y > topY) { snapping = true; scrollVP(nat - LH, true); setTimeout(() => { snapping = false; lastSnapST = vp.scrollTop; }, 460); }
  }
  function snapLive() {
    if (snapping || !L || !content || S.view === "list" || S.loading || paging || rmOn() === "x") return;
    if (document.querySelector(".bd-sb.drag")) return;
    const nat = secs.hist.el.offsetTop + L.secs.hist.h, y = nat - vp.scrollTop, vh = vp.clientHeight, bh = L.band.h;
    const topY = LH, botY = vh - bh;
    if (y <= topY + 2 || y >= botY - 2 || botY <= topY) return;
    const toTop = (y - topY) < (botY - y);
    snapping = true;
    scrollVP(toTop ? nat - LH : nat + bh - vh, true);
    setTimeout(() => { snapping = false; }, 480);
  }

  function viewport() {
    vp.innerHTML =
      '<div class="bd-content" id="bd-content">' +
        '<div class="bd-lanes" id="bd-lanes"><span class="bd-lane-g">' + (S.view === "gantt" ? "Time" : "Order") + "</span></div>" +
        '<div class="bd-guides" id="bd-guides"></div>' +
        '<svg class="bd-edges" id="bd-edges"></svg>' +
        '<section class="bd-sec" id="bd-sec-hist"><div class="bd-sech"></div><div class="bd-layer"></div></section>' +
        '<div class="bd-now" id="bd-now"><div class="bd-now-h"></div><div class="bd-layer"></div></div>' +
        '<section class="bd-sec" id="bd-sec-plan"><div class="bd-sech"></div><div class="bd-layer"></div></section>' +
        '<section class="bd-sec" id="bd-sec-nq"><div class="bd-sech"></div><div class="bd-layer"></div></section>' +
      "</div>";
    content = $("#bd-content"); lanesEl = $("#bd-lanes"); guidesEl = $("#bd-guides"); svg = $("#bd-edges"); bandEl = $("#bd-now");
    ["hist", "plan", "nq"].forEach((s) => { const el = $("#bd-sec-" + s); secs[s] = { el, layer: $(".bd-layer", el), head: $(".bd-sech", el) }; });
    R.clear(); RL.clear(); laneEls.clear(); guideEls.clear(); cols = []; colMap = {};
    content.addEventListener("mouseover", onHover);
    content.addEventListener("mouseleave", () => { clearTimeout(hoverT); if (!lockId) hoverT = setTimeout(() => { if (!lockId) setHover(null); }, 200); });
    lockId = null;
    lt = document.createElement("div"); lt.className = "bd-lt";
    lt.innerHTML = '<button type="button" data-lt="lock" title="Lock this dependency tree">' + I.lock + '</button><button type="button" data-lt="fit" title="Zoom out to fit this tree">' + I.fit + '</button><button type="button" data-lt="tree" title="View the whole tree">' + I.eye + "</button>";
    content.appendChild(lt);
    content.addEventListener("click", (e) => {
      const eh = e.target.closest(".bd-eh");
      if (eh) { e.stopPropagation(); lockTree(eh.dataset.e); return; }
      const b = e.target.closest("[data-lt]");
      if (b) { e.stopPropagation(); if (b.dataset.lt === "lock") { if (lockId) unlock(); else if (hoverId) { lockId = hoverId; lt.classList.add("locked"); } } else if (lockId) { if (b.dataset.lt === "fit") fitTree(lockId); else openTree(lockId); } return; }
      if (e.target.closest("[data-min]")) { S.liveMin = !S.liveMin; writeURL(); relayout(); return; }
      const sd = e.target.closest("[data-sid]"); if (sd) { openModal(D.byId[sd.dataset.sid]); return; }
      const st = e.target.closest("[data-ast]"); if (st) { const v = st.dataset.ast.split(","), same = S.f.astate.join(",") === v.join(","); S.f.astate = same ? [] : v; if (S.liveMin && !same) { S.liveMin = false; writeURL(); relayout(); } filtersChanged(); return; }
      const c = e.target.closest(".bd-card");
      if (lockId) { if (c && chainOf(lockId).has(c.dataset.id)) openModal(D.byId[c.dataset.id]); return; }
      if (c) openModal(D.byId[c.dataset.id]);
    });
  }

  function relayout() {
    if (S.loading) return renderLoading();
    lastEpic = S.f.epic.join(",");
    if (S.histFrom == null) initHistFrom();
    { const ds = histDays(); if (ds.length && S.span > 1) { const need = ds[Math.max(0, ds.length - S.span)]; if (S.histFrom > need) S.histFrom = need; } }
    if (S.view === "list") return renderList();
    if (!content) viewport();
    if (S.histFrom == null) initHistFrom();
    const avail = vp.clientWidth - gutW() - 14;
    const nEst = Math.max(4, new Set([...D.now, ...D.plan].map(colKey)).size);
    S.flow = avail / nEst < 62;
    S.K = Math.max(2, Math.floor(avail / 140));
    content.classList.toggle("flow", S.flow);
    if (lockId) unlock(); closeTree();
    L = computeLayout();
    if (svg) svg.setAttribute("height", 0);
    vp.style.setProperty("--dot", Math.max(14, 30 - 16 * Math.log(S.span) / Math.log(3)).toFixed(1) + "px");
    R.forEach((el) => el.remove()); R.clear(); RL.forEach((el) => el.remove()); RL.clear();
    const hc = D.hist.length, pc = D.plan.length;
    const shown = D.hist.filter((x) => x.end >= (S.histFrom || 0)).length;
    secs.hist.head.innerHTML = "History <em>" + (hc ? (moreHistory() ? "since " + fmtD(S.histFrom) + " — scroll up to load earlier days" : "all " + hc.toLocaleString() + " from " + fmtD(D.hist[0].start)) : "empty") + "</em>" + (hc ? '<em style="margin-left:auto;padding-right:14px">' + shown.toLocaleString() + " of " + hc.toLocaleString() + " loaded</em>" : "");
    secs.plan.head.innerHTML = "Planned <em>" + (pc ? pc + " in build-queue order · dependency waves" : "queue empty") + "</em>" + "";
    secs.nq.head.innerHTML = "Not queued <em>" + D.nq.length + " open · not in the queue</em>";
    ["hist", "plan", "nq"].forEach((s) => secs[s].el.style.height = L.secs[s].h + "px");
    bandEl.style.height = L.band.h + "px";
    const cnt = (sts) => D.now.filter((t) => sts.includes(t.agent.state)).length;
    const nr = cnt(["active"]), ns = cnt(["error", "retries", "command"]), ni = cnt(["paused", "parked"]);
    $(".bd-now-h", bandEl).innerHTML = "<b><i></i>Live</b><time>" + (S.demo === "offline" ? "cached " + fmtT(NOW - 6 * 6e4) : fmtT(NOW)) + "</time>" +
      '<span class="bd-now-st">' + (nr ? '<button type="button" class="ok" data-ast="active"><i></i>' + nr + " running</button>" : "") + (ns ? '<button type="button" class="bad" data-ast="error,retries,command"><i></i>' + ns + " stuck</button>" : "") + (ni ? '<button type="button" class="idle" data-ast="paused,parked"><i></i>' + ni + " paused" + "</button>" : "") + "</span>" +
      (S.liveMin && D.now.length ? '<span class="bd-now-sum" role="img" aria-label="' + nr + " running, " + ns + " stuck, " + ni + ' paused">' + [["ok", nr, "active"], ["bad", ns, "error,retries,command"], ["idle", ni, "paused,parked"]].filter((x) => x[1]).map((x) => '<button type="button" class="' + x[0] + '" data-ast="' + x[2] + '" style="flex:' + x[1] + '" title="' + x[1] + " " + (x[0] === "ok" ? "running" : x[0] === "bad" ? "stuck" : "paused") + '"></button>').join("") + "</span>" : "") + '<button type="button" class="bd-now-min" data-min title="' + (S.liveMin ? "Expand live" : "Minimize live") + '">' + (S.liveMin ? I.chev : I.chevU) + "</button>" + '<span class="bd-now-eta">' + (D.plan.length + D.now.length) + " to go · ETA " + (D.plan.length ? Math.round(D.plan.reduce((s, t) => s + (t.override ? t.override.hours : t.est), 0) / 4) + "h" : "—") + "</span>";
    syncAst();
    const bl = $(".bd-layer", bandEl); bl.innerHTML = !D.now.length ? '<div class="bd-now-empty">No agents are working right now.</div>' : "";
    bandEl.classList.toggle("min", S.liveMin);
    L.band.items.forEach((it) => { const el = makeCard(it); el.classList.add("noanim"); bl.appendChild(el); it.el = el; });
    content.style.setProperty("--fs", L.fs + "px");
    applyCols(visibleCols(), true);
    update(true);
  }

  function visibleCols() {
    if (S.flow) return Array.from({ length: S.K }, (_, i) => "s" + i);
    if (S.feature && D.features[S.feature]) {
      const F = S.feature, set = new Set(D.features[F].epics);
      D.all.forEach((t) => { if (t.feature === F || t.also.includes(F)) { set.add(colKey(t)); if (S.fmode === "compact") t.deps.forEach((d) => D.byId[d] && set.add(colKey(D.byId[d]))); } });
      return D.order.filter((k) => set.has(k));
    }
    /* history: columns change per whole visible day, not per card; forward (now + planned + not queued) is one fixed set */
    const st = vp.scrollTop, chh = vp.clientHeight, vis = new Set();
    const hs = L.secs.hist, htop = secs.hist.el.offsetTop, a = st - htop + LH, b = st - htop + chh;
    if (!L._dayCols) { L._dayCols = {}; hs.items.forEach((it) => { if (!it.t.end) return; const d = dayKey(it.t.end); (L._dayCols[d] = L._dayCols[d] || new Set()).add(it.key); }); }
    hs.items.forEach((it) => { if (it.t.end && it.y + it.h > a && it.y < b) L._dayCols[dayKey(it.t.end)].forEach((k) => vis.add(k)); });
    if (st + chh > htop + hs.h + 40) { if (!D._fwd) D._fwd = new Set([...D.plan, ...D.nq].filter(epicOk).map(colKey)); D._fwd.forEach((k) => vis.add(k)); }
    if (S.feature && D.features[S.feature]) D.features[S.feature].epics.forEach((k) => vis.add(k));
    if (S.f.epic.length) S.f.epic.forEach((k) => { if (vis.size === 0) vis.add(k); });
    return D.order.filter((k) => vis.has(k));
  }

  function update(force) {
    if (!L || S.loading) return;
    const st = vp.scrollTop, chh = vp.clientHeight;
    const next = visibleCols();
    if (next.length && next.join("|") !== cols.join("|")) {
      clearTimeout(colTimer);
      colTimer = setTimeout(() => { applyCols(visibleCols()); update(); }, force ? 0 : 220);
    }
    const keep = new Set(), keepL = new Set();
    const cw = content.offsetWidth;
    ["hist", "plan", "nq"].forEach((s) => {
      const sec = secs[s], lay = L.secs[s], top = sec.el.offsetTop, A = st - top - 700, B = st - top + chh + 700;
      lay.items.forEach((it) => {
        if (it.y + it.h < A || it.y > B) return;
        const uid = s + ":" + it.t.id; keep.add(uid);
        let el = R.get(uid);
        if (!el) { el = makeCard(it); el.classList.add("noanim"); sec.layer.appendChild(el); R.set(uid, el); requestAnimationFrame(() => requestAnimationFrame(() => el.classList.remove("noanim"))); }
        place(el, it);
      });
      lay.marks.forEach((m, i) => {
        if (m.y + m.h < A || m.y > B) return;
        const uid = s + ":m" + i; keepL.add(uid);
        let el = RL.get(uid);
        if (!el) {
          el = document.createElement("div"); el.className = "bd-mk " + m.kind;
          el.innerHTML = m.kind === "empty" ? "<b>" + esc(m.label) + "</b><p>" + esc(m.sub) + "</p>" : m.label ? "<span>" + esc(m.label) + (m.sub ? ' <em style="font-style:normal;color:var(--faint)">· ' + esc(m.sub) + "</em>" : "") + "</span>" : "";
          sec.layer.appendChild(el); RL.set(uid, el);
        }
        const g = gutW();
        el.style.top = m.y + "px"; el.style.height = m.h + "px"; el.style.left = (m.kind === "wave" ? 12 : g) + "px"; el.style.width = (cw - (m.kind === "wave" ? 12 : g) - 12) + "px";
      });
      lay.labels.forEach((lb, i) => {
        if (lb.y < A || lb.y > B) return;
        const uid = s + ":l" + i; keepL.add(uid);
        if (RL.has(uid)) return;
        const el = document.createElement("div"); el.className = "bd-lbl" + (lb.tick ? " tick" : "") + (lb.wave ? " wave" : ""); el.style.top = lb.y + "px";
        el.innerHTML = (lb.day ? "<b>" + esc(lb.day) + "</b>" : "") + "<span>" + (lb.tk ? I.ticket : "") + esc(lb.t) + "</span>";
        sec.layer.appendChild(el); RL.set(uid, el);
        if (lb.line) { const ln = document.createElement("div"); ln.className = "bd-dl"; ln.style.top = (lb.y - 6) + "px"; sec.layer.appendChild(ln); RL.set(uid + "d", ln); }
      });
    });
    R.forEach((el, uid) => { if (!keep.has(uid)) { el.remove(); R.delete(uid); } });
    RL.forEach((el, uid) => { const base = uid.endsWith("d") ? uid.slice(0, -1) : uid; if (!keepL.has(base)) { el.remove(); RL.delete(uid); } });
    const nb = $("#bd-nowbtn");
    if (nb) { const r = bandEl.getBoundingClientRect(), v = vp.getBoundingClientRect(); nb.classList.toggle("at", r.top > v.top + LH + 30 && r.bottom < v.bottom - 30); }
    drawEdges(false);
    if (S.ready && !paging && st < 260 && moreHistory()) loadEarlier();
  }
  let paging = false;
  const histDays = () => D._days || (D._days = [...new Set(D.hist.map((t) => { const d = new Date(t.end); d.setHours(0, 0, 0, 0); return d.getTime(); }))].sort((a, b) => a - b));
  const moreHistory = () => { const ds = histDays(); return ds.length && S.histFrom > ds[0]; };
  function initHistFrom() { const ds = histDays(); S.histFrom = ds.length ? ds[Math.max(0, ds.length - (D.kind === "dense" ? 1 : 2))] : 0; }
  function loadEarlier() {
    const ds = histDays(), i = ds.indexOf(S.histFrom);
    if (i <= 0) return;
    paging = true;
    S.histFrom = ds[i - 1];
    const oldH = L.secs.hist.h, oldTop = vp.scrollTop;
    try { relayout(); vp.scrollTop = oldTop + (L.secs.hist.h - oldH); update(); }
    finally { paging = false; }
  }

  function place(el, it) {
    const c = it.sec === "now" ? bandMap[it.key] : colMap[it.key];
    el.style.top = it.y + "px"; el.style.height = it.h + "px";
    if (!c) { el.style.opacity = "0"; el.style.pointerEvents = "none"; if (!el.style.left) el.style.left = "0px"; return; }
    const lanes = it.lanes || 1, lw = c.w / lanes;
    el.style.left = (c.x + (it.lane || 0) * lw) + "px";
    let ww = lw - (lanes > 1 ? 4 : 0);
    if ((el.classList.contains("mini") || el.classList.contains("bar")) && !S.flow) ww = Math.min(ww, 70);
    el.style.width = ww + "px";
    el.style.opacity = ""; el.style.pointerEvents = "";
  }

  function applyCols(next, immediate) {
    if (!next.length) next = cols.length ? cols : ["bugs", "design", "infra", "docs"];
    cols = next;
    const w = vp.clientWidth, g = gutW();
    const maxW = 520, gap = S.flow ? 10 : 16;
    const n = cols.length, avail = w - g - 14;
    let cw = Math.min(S.flow ? 1e9 : maxW, (avail - gap * (n - 1)) / n);
    lanesEl.style.setProperty("--g", gap + "px");
    colMap = {}; cols.forEach((k, i) => colMap[k] = { x: g + i * (cw + gap), w: cw });
    colMap.g = { x: g, w: avail };
    { const BK = (L && L.band.BK) || 1, bg = 16, bw = Math.min(380, (avail - bg * (BK - 1)) / BK); bandMap = {}; for (let i = 0; i < BK; i++) bandMap["b" + i] = { x: g + i * (bw + bg), w: bw }; }
    content.style.width = w + "px";
    if (S.flow) { laneEls.forEach((el) => el.remove()); laneEls.clear(); guideEls.forEach((el) => el.remove()); guideEls.clear(); lanesEl.querySelector(".bd-lane-g").textContent = "Colour = epic"; R.forEach((el) => place(el, el._it)); L.band.items.forEach((it) => place(it.el, it)); svg.classList.add("hide"); drawEdgesSoon(immediate ? 30 : 380); return; }
    lanesEl.querySelector(".bd-lane-g").textContent = S.view === "gantt" ? "Time" : "Order";
    syncKeyed(laneEls, lanesEl, "bd-lane", (k, el) => {
      const e = D.epics[k], locked = S.feature && D.features[S.feature] && D.features[S.feature].epics.includes(k);
      el.className = "bd-lane" + (e.temp ? " temp" : "") + (e.unsorted ? " unsorted" : "") + (locked ? " lock" : "");
      el.style.setProperty("--h", e.hue);
      el.title = e.temp ? e.label + " — short-lived feature epic" : e.label;
      el.innerHTML = I[e.icon] + "<span>" + esc(e.label) + "</span><em>" + (locked ? I.lock : (D.counts[k] || 0)) + "</em>";
    }, (el, k) => { const c = colMap[k]; el.style.left = c.x + "px"; el.style.width = c.w + "px"; el.classList.toggle("first", cols[0] === k); });
    syncKeyed(guideEls, guidesEl, "bd-guide", () => {}, (el, k) => { const c = colMap[k]; el.style.left = (c.x - gap / 2) + "px"; el.style.width = (c.w + gap) + "px"; });
    R.forEach((el) => place(el, el._it));
    L.band.items.forEach((it) => place(it.el, it));
    drawEdgesSoon(immediate ? 0 : 420);
  }
  function syncKeyed(map, host, cls, fill, pos) {
    const want = new Set(cols);
    map.forEach((el, k) => { if (!want.has(k) && !el.classList.contains("leave")) { el.classList.add("leave"); setTimeout(() => { if (el.classList.contains("leave")) { el.remove(); map.delete(k); } }, 300); } });
    cols.forEach((k) => {
      let el = map.get(k);
      if (el && el.classList.contains("leave")) { el.classList.remove("leave"); }
      if (!el) { el = document.createElement("div"); fill(k, el); el.classList.add(cls, "enter"); host.appendChild(el); map.set(k, el); pos(el, k); el.getBoundingClientRect(); el.classList.remove("enter"); }
      else { const lv = el.classList.contains("leave"); fill(k, el); el.classList.add(cls); if (lv) el.classList.add("leave"); pos(el, k); }
    });
  }

  /* ---------- cards ---------- */
  function cardDetail(it) {
    if (!it.gantt && !it.gt && !(S.view === "gantt" && it.sec === "hist")) return L.det;
    const fs = L.fs, tiers = ["bar", "mini", "line", "full"];
    let i = it.h >= 8.8 * fs ? 3 : it.h >= 2.1 * fs ? 2 : it.h >= 20 ? 1 : 0;
    if ((it.lanes || 1) >= 3) i = Math.min(i, 1); else if ((it.lanes || 1) >= 2) i = Math.min(i, 2);
    return tiers[Math.min(i, tiers.indexOf(L.base))];
  }
  function makeCard(it) {
    const t = it.t, e = D.epics[colKey(t)], det = cardDetail(it);
    const el = document.createElement("div");
    el._it = it; el.dataset.id = t.id;
    const ag = t.sec === "now" ? AST[t.agent.state] : null;
    const gplan = it.gantt;
    el.className = "bd-card " + det + " " + t.sec + (t.status === "failed" ? " failed" : "") + (ag ? " ag-" + ag.cls : "") + (it.ghost ? " ghost" : "") + (e.unsorted ? " unsorted" : "") +
      (gplan ? " gplan" : "") + (t.sec === "plan" && (t.cue.failed || t.cue.blockedChain) ? " blk" : "") + (t.agent && det === "full" ? " has-ag" : "");
    el.style.setProperty("--h", e.hue);
    if (t.feature) el.style.setProperty("--ft", D.features[t.feature].hue);
    if (t.sec === "now") { el.style.setProperty("--pct", t.pct + "%"); el.style.setProperty("--ph", Math.round(42 + t.pct * 1.03)); }
    if ((det === "mini" && it.h > 34) || (det === "line" && it.h > 3.2 * L.fs)) el.classList.add("tall");
    const glow = ag ? '<span class="bd-glow"></span>' : "";
    const glyph = "";
    const logo = t.agent && det === "full" ? '<span class="bd-ag' + (MODELS[t.agent.model].fill ? " fill" : "") + '" title="' + MODELS[t.agent.model].full + (ag ? " · " + ag.label : "") + '"><img src="' + MODELS[t.agent.model].logo + '" alt="' + MODELS[t.agent.model].name + '">' + glyph + "</span>" : "";
    const fd = t.feature ? '<span class="bd-fd" title="' + esc(D.features[t.feature].label) + '"></span>' : "";
    if (det === "bar") { el.innerHTML = glow + '<div class="bd-in" title="#' + t.num + " · " + esc(t.title) + (ag ? " · " + ag.label : "") + '"></div>'; decorate(el); return el; }
    if (det === "line") {
      el.innerHTML = glow + '<div class="bd-in" title="#' + t.num + " · " + esc(t.title) + (ag ? " · " + ag.label : "") + '"><span class="bd-dot"></span><span class="bd-id">#' + t.num + '</span><span class="bd-title">' + esc(t.title) + "</span>" +
        (t.sec === "now" ? '<img class="bd-lg" src="' + MODELS[t.agent.model].logo + '" alt=""><span class="bd-bar"><i style="width:' + t.pct + '%"></i></span>' : t.status === "failed" ? '<span class="bd-lx">' + I.warn + "</span>" : "") + "</div>";
      decorate(el); return el;
    }
    if (det === "mini") {
      el.innerHTML = glow + '<div class="bd-in" title="#' + t.num + " · " + esc(t.title) + (ag ? " · " + ag.label : "") + '"><span class="bd-dot"></span><span class="bd-id">#' + t.num + "</span></div>";
      decorate(el); return el;
    }
    const top = '<div class="bd-top"><span class="bd-ic">' + I[t.type === "bug" ? "bug" : t.type === "docs" ? "docs" : t.type === "chore" ? "chore" : (e.key === "design" ? "pen" : "feature")] + '</span><span class="bd-id">#' + t.num + "</span>" + fd +
      (det === "compact" ? '<span class="bd-title" style="flex:1;min-width:0">' + esc(t.title) + "</span>" : '<span class="bd-cx" style="--cxh:' + [145, 110, 80, 50, 25][t.cx - 1] + '" title="Complexity ' + t.cx + '/5 · ' + t.pts + ' pts">' + CX[t.cx - 1] + "</span>") + "</div>";
    const title = det === "full" ? '<div class="bd-title">' + esc(t.title) + "</div>" : "";
    let body = "", status = "";
    if (t.sec === "hist") {
      const hrs = (t.end - t.start) / H;
      if (S.view === "gantt" && det === "full") body = '<div class="bd-time">' + fmtD(t.start) + " " + fmtT(t.start) + "<br>→ " + (dayKey(t.start) === dayKey(t.end) ? "" : fmtD(t.end) + " ") + fmtT(t.end) + '</div><div class="bd-badges"><span class="h">' + fmtH(hrs) + "</span><span>" + t.pts + " pts</span></div>";
      status = '<div class="bd-status"><span>' + (t.status === "failed" ? "Failed · closed" : "Merged") + "</span><span>" + (S.view === "gantt" ? (det === "full" ? "" : fmtH(hrs)) : fmtD(t.end)) + "</span></div>";
      if (S.view === "gantt" && det === "full") status = "";
    } else if (t.sec === "now") {
      status = '<div class="bd-status"><span>' + ag.label + "</span><span>" + t.pct + '%</span></div><span class="bd-bar"><i style="width:' + t.pct + '%"></i></span>';
    } else if (t.sec === "plan") {
      const c = t.cue, cues = [];
      if (c.promoted) cues.push('<span class="bd-q promo">' + I.up + " promoted " + c.promoted + "</span>");
      if (c.held) cues.push('<span class="bd-q held" title="' + esc(c.held) + '">' + I.lock + " held</span>");
      if (c.wait && !c.blockedChain) cues.push('<span class="bd-q">' + I.hourglass + " waits on #" + c.wait + "</span>");
      if (c.blockedChain && !c.failed) cues.push('<span class="bd-q" style="color:var(--block-ink);border-color:var(--block-line)">' + I.warn + " prereq chain failed</span>");
      if (t.override) cues.push('<span class="bd-q ovr" title="' + esc(t.override.reason) + '">' + I.pencil + " estimate overridden</span>");
      if (det === "full") body = c.failed ? '<div class="bd-alert">' + I.warn + "<span>Prereq #" + c.failed.by + " failed · blocks " + c.failed.blocks.map((n) => "#" + n).join(" ") + "</span></div>" : (cues.length ? '<div class="bd-cues">' + cues.join("") + "</div>" : "");
      const est = t.override ? t.override.hours : t.est;
      status = '<div class="bd-status"><span>Q' + t.qpos + (c.held ? " · held" : c.failed ? " · prereq failed" : c.wait ? " · waiting" : " · queued") + "</span><span>≈" + est + "h · " + t.pts + " pts</span></div>";
    } else {
      status = '<div class="bd-status"><span>Open · not queued</span><span>' + t.pts + " pts</span></div>";
    }
    el.innerHTML = glow + '<div class="bd-in">' + top + title + body + status + "</div>" + logo;
    decorate(el);
    return el;
  }
  function decorate(el) {
    const t = D.byId[el.dataset.id], F = S.feature;
    const inFeat = F && t.feature === F, also = F && !inFeat && t.also.includes(F);
    const ghost = el.classList.contains("ghost");
    el.classList.toggle("dim", !match(t) || (!!F && S.fmode === "focus" && !inFeat && !also && !ghost));
    el.classList.toggle("also", !!also);
    el.classList.toggle("feat-on", !!inFeat);
    if (F) el.style.setProperty("--fh", D.features[F].hue);
  }
  const decorateAll = () => { R.forEach(decorate); if (L) L.band.items.forEach((it) => decorate(it.el)); drawEdgesSoon(10); };

  /* ---------- edges ---------- */
  let edgeSig = "", edgeUntil = 0;
  function drawEdgesSoon(ms) {
    const was = edgeUntil > performance.now();
    edgeUntil = performance.now() + (ms || 0);
    if (was) return;
    const loop = () => { drawEdges(true); if (performance.now() < edgeUntil) requestAnimationFrame(loop); };
    requestAnimationFrame(loop);
  }
  function drawEdges(force) {
    if (!content || !L) return;
    const cr = content.getBoundingClientRect();
    const vis = new Map();
    R.forEach((el) => { if (el.style.opacity !== "0") vis.set(el.dataset.id, el); });
    L.band.items.forEach((it) => { if (it.el.style.opacity !== "0") vis.set(it.t.id, it.el); });
    const sig = [...vis.keys()].join(",") + "|" + cols.join(",") + "|" + hoverId + "|" + Math.round(bandEl.getBoundingClientRect().top - cr.top) + "|" + content.scrollWidth;
    if (!force && sig === edgeSig) return;
    edgeSig = sig;
    svg.setAttribute("height", 0); svg.setAttribute("width", content.scrollWidth); svg.setAttribute("height", content.scrollHeight);
    const chain = hoverId ? chainOf(hoverId) : null;
    let out = "", liveOut = "";
    vis.forEach((el, id) => {
      const t = D.byId[id];
      t.deps.forEach((did) => {
        const de = vis.get(did); if (!de) return;
        const d = D.byId[did], a = de.getBoundingClientRect(), b = el.getBoundingClientRect();
        const cls = el.classList.contains("ghost") || de.classList.contains("ghost") ? "gh" : d.status === "done" ? "ok" : d.status === "failed" || (t.cue && (t.cue.failed || t.cue.blockedChain)) ? "bad" : "bl";
        const hl = chain ? (chain.has(id) && chain.has(did) ? " hl" : " fade") : (el.classList.contains("dim") || de.classList.contains("dim") ? " fade" : "");
        let x1, y1, x2, y2, path, arrow;
        if (a.bottom <= b.top + 6) {
          x1 = a.left + a.width / 2 - cr.left; y1 = a.bottom - cr.top; x2 = b.left + b.width / 2 - cr.left; y2 = b.top - cr.top - 3;
          const dy = Math.max(18, (y2 - y1) / 2);
          path = "M" + x1 + " " + y1 + " C" + x1 + " " + (y1 + dy) + " " + x2 + " " + (y2 - dy) + " " + x2 + " " + y2;
          arrow = "M" + (x2 - 4) + " " + (y2 - 6) + " L" + x2 + " " + (y2 + 1) + " L" + (x2 + 4) + " " + (y2 - 6) + "z";
        } else {
          const right = a.right <= b.left;
          x1 = (right ? a.right : a.left) - cr.left; y1 = a.top + a.height / 2 - cr.top; x2 = (right ? b.left - 3 : b.right + 3) - cr.left; y2 = b.top + Math.min(18, b.height / 2) - cr.top;
          const dx = Math.max(20, Math.abs(x2 - x1) / 2) * (right ? 1 : -1);
          path = "M" + x1 + " " + y1 + " C" + (x1 + dx) + " " + y1 + " " + (x2 - dx) + " " + y2 + " " + x2 + " " + y2;
          arrow = right ? "M" + (x2 - 6) + " " + (y2 - 4) + " L" + (x2 + 1) + " " + y2 + " L" + (x2 - 6) + " " + (y2 + 4) + "z" : "M" + (x2 + 6) + " " + (y2 - 4) + " L" + (x2 - 1) + " " + y2 + " L" + (x2 + 6) + " " + (y2 + 4) + "z";
        }
        if (t.sec === "now" || d.sec === "now") liveOut += '<path class="bd-e ' + cls + hl + '" d="' + path + '"/><path class="bd-ea ' + cls + hl + '" d="' + arrow + '"/>';
        out += '<path class="bd-eh" data-e="' + id + '" d="' + path + '"/><path class="bd-e ' + cls + hl + '" d="' + path + '"/><path class="bd-ea ' + cls + hl + '" d="' + arrow + '"/>';
      });
    });
    svg.innerHTML = out;
    let ls = bandEl.querySelector(".bd-now-e");
    if (!ls) { ls = document.createElementNS("http://www.w3.org/2000/svg", "svg"); ls.setAttribute("class", "bd-now-e bd-edges"); bandEl.insertBefore(ls, bandEl.firstChild); }
    const br = bandEl.getBoundingClientRect();
    ls.setAttribute("width", br.width); ls.setAttribute("height", br.height);
    ls.innerHTML = '<g transform="translate(' + (cr.left - br.left) + "," + (cr.top - br.top) + ')">' + liveOut + "</g>";
    svg.classList.toggle("gantt", S.view === "gantt" && !hoverId);
    svg.classList.toggle("hov", !!hoverId);
  }
  function chainOf(id) {
    const s = new Set([id]);
    const up = (x) => (D.byId[x].deps || []).forEach((d) => { if (!s.has(d) && D.byId[d]) { s.add(d); up(d); } });
    const dn = (x) => (D.children[x] || []).forEach((c) => { if (!s.has(c)) { s.add(c); dn(c); } });
    up(id); dn(id); return s;
  }
  let lockId = null, lt = null;
  let hoverT = 0;
  function onHover(e) {
    if (!S.trees || scrolling || lockId) return;
    clearTimeout(hoverT);
    if (e.target.closest(".bd-lt")) return;
    const c = e.target.closest(".bd-card");
    if (c && !c.closest(".bd-now")) { setHover(c.dataset.id, c); return; }
    hoverT = setTimeout(() => { if (!lockId) setHover(null); }, 280);
  }
  function treeRange(id) {
    const ch = chainOf(id); let a = Infinity, b = -Infinity;
    ["hist", "plan", "nq"].forEach((sx) => L.secs[sx].items.forEach((it) => { if (ch.has(it.t.id)) { const y = secs[sx].el.offsetTop + it.y; a = Math.min(a, y); b = Math.max(b, y + it.h); } }));
    const bt = secs.hist.el.offsetTop + L.secs.hist.h;
    L.band.items.forEach((it) => { if (ch.has(it.t.id)) { a = Math.min(a, bt + it.y); b = Math.max(b, bt + it.y + it.h); } });
    return { a, b };
  }
  function fitTree(id) {
    const ch = chainOf(id);
    const oldest = Math.min(Infinity, ...[...ch].map((x) => D.byId[x]).filter((t) => t.sec === "hist").map((t) => t.end));
    if (oldest < Infinity) { const d = new Date(oldest); d.setHours(0, 0, 0, 0); if (S.histFrom > d.getTime()) S.histFrom = d.getTime(); }
    const room = vp.clientHeight - LH - 70;
    let r;
    for (const sp of SPANS) { S.span = sp; relayout(); r = treeRange(id); if (r.b - r.a <= room) break; }
    writeURL(); renderTools();
    scrollVP(Math.max(0, (r.a + r.b) / 2 - vp.clientHeight / 2 + LH / 2), false); update();
    requestAnimationFrame(() => requestAnimationFrame(() => { update(); lockTree(id); }));
  }
  function lockTree(id) {
    let el = null; R.forEach((x) => { if (x.dataset.id === id) el = x; });
    if (!el && L) L.band.items.forEach((it) => { if (it.t.id === id) el = it.el; });
    lockId = null; hoverId = "~"; setHover(id, el); lockId = id;
    if (lt) lt.classList.add("locked", "show");
  }
  function unlock() { lockId = null; if (lt) lt.classList.remove("locked", "show"); hoverId = "~"; setHover(null); }
  function setHover(id, cardEl) {
    if (id === hoverId) return; hoverId = id;
    const chain = id ? chainOf(id) : null;
    R.forEach((el) => { el.classList.toggle("hl", !!chain && chain.has(el.dataset.id) && el.dataset.id !== id); el.classList.toggle("hdim", !!chain && !chain.has(el.dataset.id)); });
    if (L) L.band.items.forEach((it) => it.el && it.el.classList.toggle("hl", !!chain && chain.has(it.t.id) && it.t.id !== id));
    if (lt) {
      if (id && cardEl && content) { const cr = content.getBoundingClientRect(), r = cardEl.getBoundingClientRect(); lt.style.left = (r.right - cr.left - 1) + "px"; lt.style.top = (r.top - cr.top + Math.max(0, r.height / 2 - 14)) + "px"; lt.classList.add("show"); }
      else if (!lockId) lt.classList.remove("show");
    }
    if (content) content.classList.toggle("hovering", !!chain);
    drawEdges(true);
  }

  /* ---------- top controls ---------- */
  /* every row: [who] [top labels / bar slot / bottom labels] — identical height + bar span everywhere */
  const CL = "assets/claude-symbol.svg", CX_ = "assets/codex-color.svg", KI = "assets/kimi-logo.png", DS = "assets/deepseek-logo.png";
  const sw = (acc, reset, win) => ({ acc, reset, win });
  const PSETS = {
    2: [
      { name: "Claude", logo: CL, session: sw([18], "1h 27m", "5h"), weekly: sw([73], "1d 2h", "7d") },
      { name: "Codex", logo: CX_, session: sw([42], "4h 10m", "5h"), weekly: sw([61], "6d 23h", "7d") },
    ],
    4: [
      { name: "Claude", logo: CL, accounts: ["Max · work", "Pro · personal"], session: sw([1, 3], "1h 27m", "5h"), weekly: sw([96, 86], "1d 2h", "7d") },
      { name: "Codex", logo: CX_, session: sw([0], "4h 10m", "5h"), weekly: sw([0], "6d 23h", "7d") },
      { name: "Kimi", logo: KI, fill: true, session: sw([9], "3h 02m", "5h"), weekly: sw([14], "3d 4h", "7d") },
      { name: "DeepSeek", logo: DS, fill: true, credits: { pct: 2, left: "$10.40", tip: [["Prepaid credits", "$10.40 of $10.65 left"]] } },
    ],
    7: [
      { name: "Claude", logo: CL, accounts: ["Max · work", "Max · lab", "Pro · personal"], session: sw([38, 71, 4], "1h 27m", "5h"), weekly: sw([96, 64, 30], "1d 2h", "7d") },
      { name: "Codex", logo: CX_, accounts: ["Pro · work", "Plus · personal"], session: sw([55, 12], "2h 41m", "5h"), weekly: sw([81, 40], "4d 9h", "7d") },
      { name: "Kimi", logo: KI, fill: true, accounts: ["Team", "Personal"], session: sw([9, 0], "3h 02m", "5h"), weekly: sw([14, 2], "3d 4h", "7d") },
      { name: "Gemini", mono: "G", hue: 250, session: sw([22], "58m", "1d"), weekly: sw([47], "5d 1h", "7d") },
      { name: "DeepSeek", logo: DS, fill: true, credits: { pct: 2, left: "$10.40", tip: [["Prepaid credits", "$10.40 of $10.65 left"]] } },
      { name: "Qwen", mono: "Q", hue: 290, credits: { pct: 63, left: "$3.70", tip: [["Prepaid credits", "$3.70 of $10.00 left"]] } },
      { name: "Mistral", mono: "M", hue: 45, session: sw([6], "2h 15m", "5h"), weekly: sw([19], "2d 6h", "7d") },
    ],
  };
  const tone = (p) => p >= 95 ? " max" : p >= 80 ? " hi" : "";
  const avg = (a) => Math.round(a.reduce((s, p) => s + p, 0) / a.length);
  const bar = (acc, cls) => '<span class="ax-bar' + (cls ? " " + cls : "") + '">' + acc.map((p) => '<span class="ax-seg"><i class="' + (p ? "" : "z") + tone(p) + '" style="width:' + p + '%"></i></span>').join("") + "</span>";
  const tipA = (head, rows) => esc(JSON.stringify([head, rows]));
  const ln = (o) => '<div class="ax-ln' + (o.tag ? " t" : "") + '" data-tip="' + tipA(o.head, o.rows) + '">' + (o.tag ? '<span class="ax-tg">' + o.tag + "</span>" : "") +
    '<span class="ax-pc' + tone(o.pct) + '">' + (o.pct == null ? "" : o.pct + "%") + "</span>" + o.bar + '<span class="ax-rs">' + (o.reset ? "<span>" + o.reset + (o.win ? "<em>/" + o.win + "</em>" : "") + "</span>" + I.cycle : o.right || "") + "</span></div>";
  const whoH = (p) => '<div class="ax-who" title="' + esc(p.name) + '">' + (p.logo ? '<img class="' + (p.fill ? "fill" : "") + '" src="' + p.logo + '" alt="">' : p.icon ? '<span class="ax-ic">' + p.icon + "</span>" : '<span class="ax-mono"' + (p.hue ? ' style="background:oklch(.6 .16 ' + p.hue + ')"' : "") + ">" + p.mono + "</span>") + "<b>" + p.name + "</b>" +
    (p.accounts ? '<span class="ax-x">×' + p.accounts.length + "</span>" : "") + "</div>";
  const winTip = (p, w, label) => p.accounts ? p.accounts.map((n, i) => [n, w.acc[i] + "%"]) : [[label + " window " + w.win, w.acc[0] + "% used"]];
  const prow = (p) => {
    let lines;
    if (p.credits) lines = ln({ pct: p.credits.pct, bar: bar([p.credits.pct]), right: '<b class="ax-usd">' + p.credits.left + "</b>", head: p.name + " · credits", rows: p.credits.tip });
    else if (p.none) lines = ln({ pct: null, bar: '<span class="ax-bar none"></span>', right: '<span class="ax-no">not observed</span>', head: p.name, rows: [["Limits", "not reported by provider"]] });
    else lines = ln({ pct: avg(p.session.acc), bar: bar(p.session.acc), reset: p.session.reset, win: p.session.win, head: p.name + " · resets in " + p.session.reset, rows: winTip(p, p.session, "Session") }) +
      ln({ pct: avg(p.weekly.acc), bar: bar(p.weekly.acc), reset: p.weekly.reset, win: p.weekly.win, head: p.name + " · resets in " + p.weekly.reset, rows: winTip(p, p.weekly, "Weekly") });
    return '<div class="ax-r2">' + whoH(p) + '<div class="ax-lns">' + lines + "</div></div>";
  };
  function renderUsage() {
    const P = PSETS[S.models], lay = P.length >= 7 ? "cols" : "rows";
    const apis =
      '<div class="ax-r2">' + whoH({ name: "GitHub", icon: I.github }) + '<div class="ax-lns">' +
        ln({ tag: "core", pct: 5, bar: bar([5]), reset: "37m", win: "1h", head: "GitHub core · resets in 37m", rows: [["Requests left", "4,736 of 5,000"]] }) +
        ln({ tag: "gql", pct: 0, bar: bar([0]), reset: "20m", win: "1h", head: "GitHub GraphQL · resets in 20m", rows: [["Points left", "4,998 of 5,000"]] }) + "</div></div>" +
      '<div class="ax-r2">' + whoH({ name: "Search", icon: I.bars }) + '<div class="ax-lns">' +
        ln({ tag: "credits", pct: 0, bar: bar([0]), reset: "22d", win: "30d", head: "Search · renews in 22d", rows: [["Credits left", "90.0K"]] }) + "</div></div>";
    $("#bd-usage").innerHTML = '<div class="ax-usage n' + P.length + " lay-" + lay + '">' +
      '<section class="ax-uc api"><div class="ax-uh">APIs<span>2 APIs</span></div><div class="ax-rows2">' + apis + "</div></section>" +
      '<section class="ax-uc mdl"><div class="ax-uh">Models<button type="button" class="ax-cnt" id="ax-cnt" title="Demo · cycle 2 / 4 / 7 models">' + P.length + " models</button></div>" +
        '<div class="ax-rows2">' + P.map(prow).join("") + "</div></section></div>";
    $("#ax-cnt").addEventListener("click", () => { S.models = S.models === 4 ? 7 : S.models === 7 ? 2 : 4; writeURL(); renderUsage(); });
    fitResets(); if (document.fonts && document.fonts.ready) document.fonts.ready.then(fitResets);
  }
  function fitResets() {
    $$("#bd-usage .ax-uc").forEach((sec) => {
      let w = 0;
      $$(".ax-rs", sec).forEach((e) => { e.style.width = "max-content"; w = Math.max(w, e.getBoundingClientRect().width); e.style.width = ""; });
      sec.style.setProperty("--rsw", Math.ceil(w) + "px");
    });
  }
  let axPop = null, axT = 0;
  function wireUsagePop() {
    const host = $("#bd-usage");
    axPop = document.createElement("div"); axPop.className = "ax-pop"; document.body.appendChild(axPop);
    host.addEventListener("mouseover", (e) => {
      const l = e.target.closest(".ax-ln"); if (!l) return;
      clearTimeout(axT);
      const [head, rows] = JSON.parse(l.dataset.tip);
      axPop.innerHTML = "<b>" + esc(head) + "</b>" + rows.map((r) => "<div><span>" + esc(r[0]) + "</span><em>" + esc(r[1]) + "</em></div>").join("");
      const r = l.getBoundingClientRect(); axPop.style.left = (r.left + 28) + "px"; axPop.style.top = (r.top - 6) + "px"; axPop.classList.add("show");
    });
    host.addEventListener("mouseout", (e) => { const l = e.target.closest(".ax-ln"); if (l && !l.contains(e.relatedTarget)) axT = setTimeout(() => axPop.classList.remove("show"), 60); });
    window.addEventListener("scroll", () => axPop.classList.remove("show"), { passive: true, capture: true });
  }
  function renderOffline() {
    $("#bd-offline").innerHTML = S.demo === "offline" ? '<div class="bd-offline">' + I.warn + "<div><b>Daemon offline</b> · last heartbeat 6 min ago (14:14). Showing cached state — agent states and usage may be stale.</div>" + '<button class="btn secondary sm" type="button" id="bd-retry">Reconnect</button></div>' : "";
    root.classList.toggle("stale", S.demo === "offline");
    const b = $("#bd-retry"); if (b) b.addEventListener("click", () => setDemo("live"));
  }
  function renderFeatures() {
    const fs = Object.values(D.features).filter((f) => D.all.some((t) => t.feature === f.key && t.sec !== "hist") || f.key === "khala");
    if (false) $("#bd-feats").innerHTML = "<span>Features</span>" + fs.map((f) => { const s = featStats(f.key); return '<button class="bd-fp' + (S.feature === f.key ? " on" : "") + '" type="button" data-f="' + f.key + '" style="--fh:' + f.hue + '"><i></i>' + esc(f.label) + "<em>" + s.pct + "%</em></button>"; }).join("");
    if (false) $("#bd-feats .bd-fp").forEach((b) => b.addEventListener("click", () => setFeature(S.feature === b.dataset.f ? null : b.dataset.f)));
    const host = $("#bd-fh");
    if (!S.feature || !D.features[S.feature]) { host.innerHTML = ""; return; }
    const f = D.features[S.feature], s = featStats(f.key);
    const max = Math.max(...s.spark), min = Math.min(...s.spark), n = s.spark.length;
    const pts = s.spark.map((v, i) => (n === 1 ? 0 : i / (n - 1) * 74 + 1).toFixed(1) + "," + (20 - (max === min ? 10 : (v - min) / (max - min) * 18)).toFixed(1)).join(" ");
    host.innerHTML = '<div class="bd-fh" style="--fh:' + f.hue + '">' +
      '<div class="bd-fh-name"><i></i>' + esc(f.label) + "</div>" +
      '<div class="bd-kv"><small>Done</small><b>' + s.done + "/" + s.total + "</b></div>" +
      '<div class="bd-kv"><small>Weighted</small><b>' + s.pct + "%</b></div>" +
      '<div class="bd-kv"><small>Scope · original → now</small><b>' + s.orig + " → " + s.total + (s.added ? " <em>+" + s.added + "</em>" : "") +
        '<svg class="sp" viewBox="0 0 76 22"><polyline points="' + pts + '" fill="none" stroke="oklch(.68 .14 ' + f.hue + ')" stroke-width="1.6" stroke-linejoin="round"/></svg></b></div>' +
      '<div style="display:flex;align-items:center;gap:.5rem;justify-self:end"><div class="bd-seg"><button type="button" data-m="focus" class="' + (S.fmode === "focus" ? "on" : "") + '">' + I.focus + 'Focus</button><button type="button" data-m="compact" class="' + (S.fmode === "compact" ? "on" : "") + '">' + I.compact + 'Compact</button></div><button class="bd-x" type="button" id="bd-fx" aria-label="Clear feature">' + I.x + "</button></div>" +
      '<div class="bd-fh-ep">' + f.epics.map((k) => '<span class="bd-chip" style="color:oklch(.7 .13 ' + f.hue + ')">' + I.lock + esc(D.epics[k].label) + "</span>").join("") + (s.also ? '<span class="bd-chip">+' + s.also + " also affect</span>" : "") + "</div>" +
    "</div>";
    $$("#bd-fh [data-m]").forEach((b) => b.addEventListener("click", () => { S.fmode = b.dataset.m; writeURL(); renderFeatures(); relayout(); }));
    $("#bd-fx").addEventListener("click", () => setFeature(null));
  }
  function setFeature(k) {
    const wasCompact = S.feature && S.fmode === "compact";
    S.feature = k; if (!k) S.fmode = "focus";
    writeURL(); renderFeatures(); renderFilters();
    if (wasCompact || (k && S.fmode === "compact")) relayout(); else { decorateAll(); applyCols(visibleCols()); }
  }
  const FOPTS = () => ({
    model: { label: "Model", opts: Object.keys(MODELS).map((v) => [v, MODELS[v].name, MODELS[v].logo]) },
    feature: { label: "Feature", opts: Object.values(D.features).filter((f) => D.all.some((t) => t.feature === f.key)).slice(-6).map((f) => [f.key, f.label + "  " + featStats(f.key).pct + "%", null, f.hue]) },
    epic: { label: "Epic", opts: D.order.filter((k) => D.counts[k]).map((k) => [k, D.epics[k].label, null, D.epics[k].unsorted ? null : D.epics[k].hue]) },
    tstate: { label: "Ticket", opts: [["merged", "Merged", "merged"], ["failed", "Failed", "failed"], ["in progress", "In progress", "active"], ["queued", "Queued", "queued"], ["held", "Held", "held"], ["blocked", "Blocked", "blocked"], ["open", "Not queued", "open"]].map((o) => [o[0], o[1], null, null, o[2]]) },
    astate: { label: "Agent", opts: Object.keys(AST).map((v) => [v, AST[v].label, null, null, AST[v].cls]).concat([["none", "No agent", null, null, "open"]]) },
  });
  function renderFilters() {
    const O = FOPTS(), host = $("#bd-filters");
    let html = I.filter;
    const sel = (k) => k === "feature" ? (S.feature ? [S.feature] : []) : S.f[k];
    FKEYS.forEach((k) => { const n = sel(k).length; html += '<button class="bd-fg' + (n ? " has" : "") + (S.pop === k ? " open" : "") + '" type="button" data-g="' + k + '">' + O[k].label + (n ? " <b>" + n + "</b>" : "") + I.chev + "</button>"; });
    if (FKEYS.some((k) => sel(k).length)) html += '<button class="bd-fclear" type="button" id="bd-fclr">Clear</button>';
    if (S.pop) html += '<div class="bd-pop" id="bd-pop">' + O[S.pop].opts.map((o) => '<button class="bd-opt' + (o[4] ? " lst st-" + o[4] : "") + (sel(S.pop).includes(o[0]) ? " on" : "") + '" type="button" data-o="' + esc(o[0]) + '">' + (o[4] ? "<u></u>" : "") + (o[2] ? '<img src="' + o[2] + '" alt="">' : o[3] != null ? '<i style="background:oklch(.66 .14 ' + o[3] + ')"></i>' : "") + esc(o[1]) + "</button>").join("") + "</div>";
    host.innerHTML = html;
    $$("[data-g]", host).forEach((b) => b.addEventListener("click", (e) => { e.stopPropagation(); S.pop = S.pop === b.dataset.g ? null : b.dataset.g; renderFilters(); }));
    $$("[data-rm]", host).forEach((b) => b.addEventListener("click", () => { const [k, v] = b.dataset.rm.split("|"); if (k === "feature") return setFeature(null); S.f[k] = S.f[k].filter((x) => x !== v); filtersChanged(); }));
    const clr = $("#bd-fclr"); if (clr) clr.addEventListener("click", () => { FKEYS.forEach((k) => S.f[k] = []); S.pop = null; if (S.feature) setFeature(null); else filtersChanged(); });
    const pop = $("#bd-pop");
    if (pop) {
      const btn = $('[data-g="' + S.pop + '"]', host); pop.style.left = btn.offsetLeft + "px";
      $$("[data-o]", pop).forEach((b) => b.addEventListener("click", (e) => { e.stopPropagation(); const k = S.pop, v = b.dataset.o; if (k === "feature") { S.pop = null; return setFeature(S.feature === v ? null : v); } S.f[k] = S.f[k].includes(v) ? S.f[k].filter((x) => x !== v) : S.f[k].concat(v); filtersChanged(); }));
    }
  }
  const syncAst = () => { const k = S.f.astate.join(","); $$(".bd-now-h [data-ast]").forEach((b) => b.classList.toggle("on", !!k && b.dataset.ast === k)); };
  let lastEpic = "";
  function filtersChanged() {
    writeURL(); renderFilters(); syncAst();
    const e = S.f.epic.join(",");
    if (S.view === "list") renderList(); else if (e !== lastEpic) { D._fwd = null; relayout(); } else decorateAll();
  }
  function renderTools() {
    const off = S.demo === "offline", vb = (v, ic, l) => '<button type="button" data-v="' + v + '" class="' + (S.view === v ? "on" : "") + '" title="' + l + '">' + I[ic] + "<span>" + l + "</span></button>";
    $("#bd-tools-l").innerHTML =
      '<div class="bd-seg vw" role="tablist" aria-label="View">' + vb("graph", "graph", "Timeline") + vb("gantt", "gantt", "Gantt") + vb("list", "list", "List") + "</div>" +
      (S.view === "list" ? "" : "" +
"");
    $("#bd-tools").innerHTML =
      '<button class="bd-live" type="button" id="bd-nowbtn" title="Jump to live"><i></i>Live</button>' +
      (S.view === "list" ? "" : '<div class="bd-seg ic bd-cal" aria-label="Range">' + [[1, "Day"], [7, "Week"], [30, "Month"]].map((o) => '<button type="button" data-span="' + o[0] + '" class="' + (calNear() === o[0] ? "on" : "") + '" title="' + o[1] + '">' + calIc(o[0] === 1 ? "1" : o[0] === 7 ? "7" : "31") + "</button>").join("") + "</div>" +
        '<div class="bd-seg bd-zoom" aria-label="Zoom"><button type="button" data-z="1" title="Zoom out · more days" aria-label="Zoom out"' + (S.span >= SPANS[SPANS.length - 1] ? " disabled" : "") + '>−</button><span class="bd-zv" title="' + S.span + (S.span === 1 ? " day" : " days") + ' in view">' + Math.round(100 / S.span) + '%</span><button type="button" data-z="-1" title="Zoom in · fewer days" aria-label="Zoom in"' + (S.span <= SPANS[0] ? " disabled" : "") + ">+</button></div>");
    $("#bd-status").innerHTML =
      '<span class="bd-daemon' + (off ? " off" : "") + '"><i></i>' + (off ? "Daemon offline" : "Daemon live") + "</span>" +
      (S.view === "list" ? "" : '<span class="bd-key"><span class="bd-leg"><span class="bd-leg-l"></span>Cleared</span><span class="bd-leg"><span class="bd-leg-l d"></span>Pending</span>' +
      (S.view === "gantt" ? '<span class="bd-leg"><span class="bd-leg-h"></span>Planned estimate</span>' : "") + "</span>") +
      '<label class="bd-exl">Demo data<select class="bd-sel" id="bd-ex">' + [["live", "This repo"], ["dense", "1,300 tickets"], ["newrepo", "New repo"], ["noqueue", "Empty queue"], ["offline", "Daemon offline"]].map((o) => '<option value="' + o[0] + '"' + (S.demo === o[0] ? " selected" : "") + ">" + o[1] + "</option>").join("") + "</select></label>";
    $$("#bd-tools-l [data-v]").forEach((b) => b.addEventListener("click", () => { if (S.view === b.dataset.v) return; S.view = b.dataset.v; writeURL(); renderTools(); viewport(); relayout(); jumpNow(true); }));
    $$("#bd-tools-l [data-d]").forEach((b) => b.addEventListener("click", () => { if (S.density === b.dataset.d) return; const f = (vp.scrollTop + vp.clientHeight / 2) / Math.max(1, vp.scrollHeight); S.density = b.dataset.d; writeURL(); renderTools(); relayout(); vp.scrollTop = f * vp.scrollHeight - vp.clientHeight / 2; update(); }));
    const tb = $("#bd-trees"); if (tb) tb.addEventListener("click", () => { S.trees = !S.trees; if (!S.trees) { if (lockId) unlock(); else setHover(null); } writeURL(); renderTools(); });
    $$("#bd-tools [data-z]").forEach((b) => b.addEventListener("click", () => { const i = SPANS.indexOf(S.span), j = Math.max(0, Math.min(SPANS.length - 1, (i < 0 ? 0 : i) + (+b.dataset.z))); setSpan(SPANS[j]); }));
    $$("#bd-tools [data-span]").forEach((b) => b.addEventListener("click", () => setSpan(+b.dataset.span)));
    $("#bd-nowbtn").addEventListener("click", () => jumpNow(false));
    $("#bd-ex").addEventListener("change", (e) => setDemo(e.target.value));
  }
  /* ---------- list view ---------- */
  const stClass = (t) => t.sec === "hist" ? (t.status === "failed" ? "failed" : "merged") : t.sec === "now" ? AST[t.agent.state].cls : t.sec === "plan" ? (t.cue.held ? "held" : t.cue.failed || t.cue.blockedChain ? "blocked" : "queued") : "open";
  const stText = (t) => t.sec === "hist" ? (t.status === "failed" ? "Failed" : "Merged") : t.sec === "now" ? AST[t.agent.state].label : t.sec === "plan" ? (t.cue.held ? "Held" : t.cue.failed || t.cue.blockedChain ? "Blocked" : t.cue.wait ? "Waiting on #" + t.cue.wait : "Queued") : "Not queued";
  function renderList() {
    L = null; content = null; R.clear(); cols = [];
    const F = S.feature, keep = (t) => epicOk(t) && match(t);
    const dim = (t) => F && S.fmode === "focus" && t.feature !== F && !t.also.includes(F);
    const row = (t) => {
      const e = D.epics[colKey(t)], m = t.agent ? MODELS[t.agent.model] : null, ups = t.deps.length, dn = (D.children[t.id] || []).length;
      const prog = t.sec === "now" ? '<span class="lr-pg" style="--pct:' + t.pct + "%;--ph:" + Math.round(42 + t.pct * 1.03) + '"><span class="bd-bar"><i style="width:' + t.pct + '%"></i></span><b>' + t.pct + "%</b></span>"
        : t.sec === "hist" ? '<span class="lr-mu">' + fmtD(t.end) + " · " + fmtH((t.end - t.start) / H) + "</span>" : t.sec === "plan" ? '<span class="lr-mu">Q' + t.qpos + " · W" + t.wave + " · ≈" + (t.override ? t.override.hours : t.est) + "h</span>" : '<span class="lr-mu">' + t.pts + " pts</span>";
      return '<div class="lr ' + t.sec + (dim(t) ? " dim" : "") + '" role="row" data-id="' + t.id + '" style="--h:' + e.hue + '">' +
        '<span class="c-id"><span class="lr-ep' + (e.unsorted ? " un" : "") + '">' + I[e.icon] + "</span>#" + t.num + "</span>" +
        '<span class="c-tt">' + esc(t.title) + (t.feature ? '<i class="lr-f" style="--ft:' + D.features[t.feature].hue + '" title="' + esc(D.features[t.feature].label) + '"></i>' : "") + "</span>" +
        '<span class="c-ep">' + esc(e.label) + "</span>" +
        '<span class="c-st"><span class="lst st-' + stClass(t) + '"><u></u>' + esc(stText(t)) + "</span></span>" +
        '<span class="c-ag">' + (m ? '<img src="' + m.logo + '" alt="">' + m.name : '<span class="lr-mu">—</span>') + "</span>" +
        '<span class="c-pg">' + prog + "</span>" +
        '<span class="c-dp" title="' + ups + " dependencies · unblocks " + dn + '">' + (ups ? "↑" + ups : "") + (dn ? " ↓" + dn : "") + "</span></div>";
    };
    const sec = (label, sub, list, extra) => list.length || extra ? '<div class="lh"><b>' + label + "</b><em>" + sub + "</em></div>" + list.map(row).join("") + (extra || "") : "";
    const now = D.now.filter(keep), plan = D.plan.filter(keep), nq = D.nq.filter(keep);
    const hist = D.hist.filter((t) => t.end >= (S.histFrom || 0) && keep(t)).sort((a, b) => b.end - a.end);
    vp.innerHTML = '<div class="bd-list" role="table"><div class="lr lr-h" role="row"><span class="c-id">Ticket</span><span class="c-tt">Title</span><span class="c-ep">Epic</span><span class="c-st">State</span><span class="c-ag">Agent</span><span class="c-pg">Progress</span><span class="c-dp">Deps</span></div>' +
      sec('<i class="lh-live"></i>Live', now.length + " running", now) +
      sec("Planned", plan.length + " in build-queue order", plan) +
      sec("Not queued", nq.length + " open", nq) +
      sec("History", hist.length + " loaded · newest first", hist, moreHistory() ? '<button type="button" class="lr-more" id="lr-more">Load earlier day</button>' : "") + "</div>";
    $$(".lr[data-id]", vp).forEach((r) => r.addEventListener("click", () => openModal(D.byId[r.dataset.id])));
    const mb = $("#lr-more"); if (mb) mb.addEventListener("click", () => { const ds = histDays(), i = ds.indexOf(S.histFrom); if (i > 0) { S.histFrom = ds[i - 1]; const st = vp.scrollTop; renderList(); vp.scrollTop = st; } });
  }
  /* ---------- whole-tree view ---------- */
  function openTree(id) {
    const host = $("#bd-tree"); if (!host) return;
    const set = chainOf(id), ids = [...set], depth = {};
    const dep = (x) => { if (depth[x] != null) return depth[x]; depth[x] = 0; let d = 0; D.byId[x].deps.forEach((p) => { if (set.has(p)) d = Math.max(d, dep(p) + 1); }); return (depth[x] = d); };
    ids.forEach(dep);
    const rows = []; ids.forEach((x) => (rows[depth[x]] = rows[depth[x]] || []).push(x));
    const oi = (x) => D.order.indexOf(colKey(D.byId[x]));
    rows.forEach((r) => r.sort((a, b) => oi(a) - oi(b) || D.byId[a].num - D.byId[b].num));
    const NW = 196, NH = 50, GX = 14, GY = 44, GW = 12, MIN = 0.8;
    host.hidden = false; content.classList.add("treeview");
    const aw = host.clientWidth - 56, ah = host.clientHeight - 96;
    const per = Math.max(2, Math.floor((aw / MIN + GX) / (NW + GX)));
    const vrows = []; rows.forEach((r) => { for (let i = 0; i < r.length; i += per) vrows.push({ ids: r.slice(i, i + per), cont: i > 0 }); });
    const widest = Math.max(...vrows.map((r) => r.ids.length));
    const natW = widest * (NW + GX) - GX;
    const pos = {}; let y = 0;
    vrows.forEach((r, ri) => { if (ri) y += r.cont ? GW : GY; const rw = r.ids.length * (NW + GX) - GX, x0 = (natW - rw) / 2; r.ids.forEach((x, i) => pos[x] = { x: x0 + i * (NW + GX), y }); y += NH; });
    const natH = y;
    const sc = Math.max(MIN, Math.min(1, aw / natW, ah / natH));
    let edges = "";
    ids.forEach((x) => D.byId[x].deps.forEach((p) => {
      if (!set.has(p)) return;
      const a = pos[p], b = pos[x], d = D.byId[p], t = D.byId[x];
      const cls = d.status === "done" ? "ok" : d.status === "failed" || (t.cue && (t.cue.failed || t.cue.blockedChain)) ? "bad" : "bl";
      const x1 = a.x + NW / 2, y1 = a.y + NH, x2 = b.x + NW / 2, y2 = b.y - 4, dy = Math.max(16, (y2 - y1) / 2);
      edges += '<path class="bd-e ' + cls + '" d="M' + x1 + " " + y1 + " C" + x1 + " " + (y1 + dy) + " " + x2 + " " + (y2 - dy) + " " + x2 + " " + y2 + '"/><path class="bd-ea ' + cls + '" d="M' + (x2 - 4) + " " + (y2 - 6) + " L" + x2 + " " + (y2 + 1) + " L" + (x2 + 4) + " " + (y2 - 6) + 'z"/>';
    }));
    const stOf = (t) => t.sec === "hist" ? (t.status === "failed" ? "Failed" : "Merged " + fmtD(t.end)) : t.sec === "now" ? AST[t.agent.state].label + " · " + t.pct + "%" : t.sec === "plan" ? "Q" + t.qpos + " · W" + t.wave : "Not queued";
    const nodes = ids.map((x) => { const t = D.byId[x], p = pos[x], ag = t.sec === "now" ? AST[t.agent.state] : null;
      return '<button type="button" class="bd-tn ' + t.sec + (ag ? " ag-" + ag.cls : "") + (t.status === "failed" ? " failed" : "") + (x === id ? " sel" : "") + '" data-id="' + x + '" style="left:' + p.x + "px;top:" + p.y + "px;width:" + NW + "px;height:" + NH + "px;--h:" + D.epics[colKey(t)].hue + '"><span class="bd-tn1"><i></i><b>#' + t.num + "</b><span>" + esc(t.title) + '</span></span><em>' + stOf(t) + "</em></button>"; }).join("");
    const r0 = D.byId[id];
    host.innerHTML = '<div class="bd-tree-h"><b>Dependency tree</b><span>#' + r0.num + " · " + ids.length + " tickets · " + rows.length + ' levels</span><button type="button" class="bd-tree-x" id="bd-tree-x">' + I.x + "Close</button></div>" +
      '<div class="bd-tree-s"><div class="bd-tree-c" style="width:' + natW * sc + "px;height:" + natH * sc + 'px"><div class="bd-tree-in" style="width:' + natW + "px;height:" + natH + "px;transform:scale(" + sc + ')"><svg class="bd-edges" width="' + natW + '" height="' + natH + '">' + edges + "</svg>" + nodes + "</div></div></div>";
    host.onclick = (e) => { e.stopPropagation(); const n = e.target.closest(".bd-tn"); if (n) { openModal(D.byId[n.dataset.id]); return; } if (e.target.closest("#bd-tree-x") || !e.target.closest(".bd-tree-c")) closeTree(); };
    const sw = $(".bd-tree-s", host), p0 = pos[id];
    sw.scrollLeft = Math.max(0, (p0.x + NW / 2) * sc - sw.clientWidth / 2);
    sw.scrollTop = Math.max(0, (p0.y + NH / 2) * sc - sw.clientHeight / 2);
  }
  function closeTree() { const host = $("#bd-tree"); if (!host) return; host.hidden = true; host.innerHTML = ""; if (content) content.classList.remove("treeview"); }
  const CALI = {
    "1": '<rect x="4" y="4" width="16" height="16" rx="2.5"/><path d="M4 9h16"/>',
    "7": '<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M3 9h18M9 9v11M15 9v11"/>',
    "31": '<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M3 9h18M3 14.5h18M9 9v11M15 9v11"/>',
  };
  const calIc = (n) => sv(CALI[n], 1.9);
  const calNear = () => [1, 7, 30].reduce((a, b) => Math.abs(Math.log(b / S.span)) < Math.abs(Math.log(a / S.span)) ? b : a);
  function setSpan(sp) {
    if (sp === S.span) return;
    S.span = sp; writeURL(); renderTools(); relayout(); jumpNow(true);
  }
  let anim = 0;
  function scrollVP(y, smooth) {
    cancelAnimationFrame(anim);
    y = Math.max(0, Math.min(y, vp.scrollHeight - vp.clientHeight));
    if (!smooth || rmOn()) { vp.scrollTop = y; return; }
    const y0 = vp.scrollTop, t0 = performance.now(), dur = 420;
    const step = (now) => { const k = Math.min(1, (now - t0) / dur), e = 1 - Math.pow(1 - k, 3); vp.scrollTop = y0 + (y - y0) * e; if (k < 1) anim = requestAnimationFrame(step); };
    anim = requestAnimationFrame(step);
  }
  function jumpNow(instant) {
    if (S.view === "list") { scrollVP(0, !instant); return; }
    if (!secs.hist || !L) return;
    const y = secs.hist.el.offsetTop + L.secs.hist.h - LH;
    scrollVP(y, !instant);
    if (instant) update();
  }
  function renderLoading() {
    content = null;
    vp.innerHTML = '<div class="bd-lanes"><div class="bd-skel-lanes"><i class="bd-skel-i"></i><i></i><i></i><i></i></div></div><div class="bd-skel">' + "<i></i>".repeat(16) + '</div><div class="bd-loading"><span class="bd-spin"></span>Loading build timeline…</div>';
    $$(".bd-skel-lanes i", vp).forEach((i) => i.style.background = "var(--surface-3)");
  }
  function setDemo(d) {
    const was = S.demo;
    S.histFrom = null; S.ready = false;
    S.demo = d; S.pop = null;
    if (d === "dense") S.span = 3; else if (was === "dense") S.span = 1;
    writeURL();
    D = dataFor(d);
    S.loading = true; renderAll();
    clearTimeout(loadingTimer);
    loadingTimer = setTimeout(() => { S.loading = false; viewport(); relayout(); jumpNow(true); S.ready = true; }, 650);
  }
  function renderAll() {
    renderUsage(); renderOffline(); renderFeatures(); renderFilters(); renderTools();
    if (S.loading) { renderLoading(); return; }
    viewport(); relayout();
  }

  /* ============================================================ MODAL */
  const MI = {
    mic: sv('<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>'),
    send: sv('<path d="M5 12h14M13 6l6 6-6 6"/>', 2.2),
    expand: sv('<path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7"/>'),
    review: sv('<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>'),
    prog: sv('<path d="M3 12h4l3-8 4 16 3-8h4"/>'),
    tool: sv('<path d="m8 8-5 4 5 4M16 8l5 4-5 4"/>'),
    pause: '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/></svg>',
    play: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>',
    down: sv('<path d="M12 5v14M5 12l7 7 7-7"/>', 2.4),
  };
  const ic = (n) => I[n] || MI[n] || "";
  const EVK = { dep: [190, "link"], commit: [255, "commit"], prog: [null, "prog"], pr: [300, "pr"], review: [85, "review"], comment: [220, "chat"], merge: [150, "merge"], fail: [25, "warn"], cmd: [25, "warn"], you: [0, "pause"] };
  const CV = {
    files: ["src/daemon/scheduler.ts", "src/daemon/retry.ts", "src/api/events.ts", "src/api/cursor.ts", "web/build/timeline.tsx", "web/build/useLayout.ts", "src/store/queue.ts", "test/scheduler.test.ts", "test/cursor.test.ts", "src/github/client.ts", "web/components/PagedList.tsx", "docs/ops/restarts.md"],
    say: ["Reading the scheduler to see where this state lives.", "Found it — the cursor drops the tiebreaker id when two timestamps collide.", "Splitting this into two commits so the migration is easy to review.", "Tests pass locally. Pushing.", "Re-running the flaky suite three times to be sure.", "That approach breaks the resume path; reverting and trying a write-ahead log instead.", "Lint and typecheck are clean. Moving on to edge cases.", "Adding a regression test before touching the fix.", "The existing helper already handles this — reusing it instead of adding a new one.", "Updating the docs to match the new behaviour."],
    code: ["const cursor = encodeCursor(row.ts, row.id);", "if (!state) return null;", "await queue.flush({ fsync: true });", "export function retryDelay(n: number) {", "  return Math.min(2 ** n * 250, MAX_DELAY);", "const page = rows.slice(0, limit + 1);", "hasMore: page.length > limit,", "log.debug(\"resume\", { id, attempt });", "const delay = 1000;", "expect(next.cursor).toBeDefined();", "if (attempt >= MAX_RETRIES) throw new RetryError(id);", "return { items: page.slice(0, limit), next };", "snapshot.version = 2;", "useEffect(() => restoreScroll(anchor), [anchor]);"],
    tools: [
      ["read_file", (r, f) => f, (r) => "read " + (60 + Math.floor(r() * 300)) + " lines"],
      ["grep", (r) => '"' + pick(r, ["retryState", "cursor", "flush(", "snapshot", "onReconnect", "MAX_DELAY"]) + '" src/', (r) => (1 + Math.floor(r() * 9)) + " matches in " + (1 + Math.floor(r() * 4)) + " files"],
      ["run_tests", (r) => pick(r, ["test/scheduler", "test/cursor", "test/api", "web/build"]), (r) => r() < 0.82 ? "✓ " + (12 + Math.floor(r() * 80)) + " passed" : "✗ 1 failed · " + (10 + Math.floor(r() * 40)) + " passed"],
      ["bash", (r) => pick(r, ["pnpm lint", "pnpm typecheck", "git status --short", "gh pr checks"]), () => "exit 0"],
    ],
    commits: ["Add regression test", "Persist state before ack", "Handle empty page", "Extract cursor helpers", "Address review feedback", "Fix flaky timer in test", "Update docs"],
    ops: ["Keep the public API unchanged if you can.", "Can you add a test for the empty case?", "Please don't touch the migration files.", "Prefer the smaller diff here."],
    replies: ["Got it — adjusting the plan.", "Understood, I'll keep that constraint for the rest of the ticket.", "Makes sense. Switching approach.", "On it."],
    prc: ["Can we name this something less generic?", "Nit: early return reads better here.", "Does this need a migration note?", "LGTM once CI is green."],
    people: ["@maya", "@devon", "@priya", "@sam"],
  };
  const diffItem = (r) => { const file = pick(r, CV.files), n = 2 + Math.floor(r() * 4), lines = []; let add = 0, del = 0; for (let i = 0; i < n; i++) { const s = r() < 0.28 ? "-" : r() < 0.85 ? "+" : " "; if (s === "+") add++; if (s === "-") del++; lines.push([s, pick(r, CV.code)]); } return { k: "diff", file, lines, add, del }; };
  const toolItem = (r) => { const T = pick(r, CV.tools), res = T[2](r); return { k: "tool", name: T[0], arg: T[1](r, pick(r, CV.files)), res, bad: res[0] === "✗" }; };
  const filler = (r) => { const x = r(); return x < 0.32 ? { k: "say", text: pick(r, CV.say) } : x < 0.74 ? toolItem(r) : diffItem(r); };
  const sha = (s) => hash(s).toString(16).padStart(8, "0").slice(0, 7);

  function convo(t) {
    const r = rng(hash(t.id + "cv")), m = MODELS[t.agent.model], items = [];
    const hist = t.sec === "hist", end = hist ? t.end : NOW, span = Math.max(0.3 * H, end - t.start);
    const frac = hist ? 1 : Math.max(0.12, t.pct / 100), total = Math.round((16 + t.cx * 9) * frac) + 4;
    const prn = 200 + (t.num % 300);
    const push = (o, i) => { o.at = t.start + span * Math.min(1, i / total); items.push(o); };
    t.deps.map((d) => D.byId[d]).filter(Boolean).forEach((d) => push({ k: "ev", ev: "dep", label: "Dependency #" + d.num + (d.status === "done" ? " merged" : d.sec === "now" ? " in progress" : " " + d.status), sub: d.title, go: d.id }, 0));
    push({ k: "sys", text: "Picked up by " + m.full + " · " + t.agent.effort + " effort" }, 0);
    push({ k: "say", text: "Reading the ticket and the surrounding code before changing anything." }, 0);
    const th = [[0.2, "op"], [0.25, "p25"], [0.35, "tc"], [0.5, "p50"], [0.55, "pr"], [0.68, "rv"], [0.75, "p75"], [0.82, "pc"]];
    let ti = 0, sinceC = 0, nextC = 4 + Math.floor(r() * 4);
    for (let i = 1; i <= total; i++) {
      const p = (i / total) * frac;
      while (ti < th.length && p >= th[ti][0]) {
        const k = th[ti++][1];
        if (k === "op") { push({ k: "op", text: pick(r, CV.ops) }, i); push({ k: "say", text: pick(r, CV.replies) }, i); }
        else if (k[0] === "p" && k.length === 3 && k !== "pr") { const pc = +k.slice(1); push({ k: "ev", ev: "prog", pct: pc, label: "Progress · " + pc + "%", sub: pc === 25 ? "Repro test written" : pc === 50 ? "Core change done, tests green" : "Edge cases and docs" }, i); }
        else if (k === "tc") push({ k: "ev", ev: "comment", label: "Comment on ticket · " + pick(r, CV.people), sub: "Can we also cover the reconnect case?" }, i);
        else if (k === "pr") push({ k: "ev", ev: "pr", label: "Opened PR #" + prn, sub: t.title }, i);
        else if (k === "rv") push({ k: "ev", ev: "review", label: "Code review · " + (1 + Math.floor(r() * 3)) + " suggestions", sub: "Reviewer agent" }, i);
        else if (k === "pc") push({ k: "ev", ev: "comment", label: pick(r, CV.people) + " commented on PR #" + prn, sub: pick(r, CV.prc) }, i);
      }
      push(filler(r), i);
      if (++sinceC >= nextC) { push({ k: "ev", ev: "commit", label: "Commit " + sha(t.id + i), sub: pick(r, CV.commits) }, i); sinceC = 0; nextC = 4 + Math.floor(r() * 4); }
    }
    const st = t.agent.state;
    if (hist && t.status === "failed") push({ k: "ev", ev: "fail", label: "CI failed 3/14 · PR #" + prn + " closed", sub: "snapshot format mismatch on restart" }, total);
    else if (hist) { push({ k: "tool", name: "bash", arg: "gh pr checks", res: "✓ 14/14 passed" }, total); push({ k: "ev", ev: "merge", label: "Merged PR #" + prn + " into main", sub: fmtD(t.end) + " " + fmtT(t.end) }, total); }
    else if (st === "error") push({ k: "ev", ev: "fail", label: "Error · attempt 2/5", sub: "ECONNRESET in websocket reconnect test" }, total);
    else if (st === "retries") push({ k: "ev", ev: "fail", label: "Retries exhausted · 5/5", sub: "rate limited by GitHub search API" }, total);
    else if (st === "command") push({ k: "ev", ev: "cmd", label: "Asked a blocking question", sub: "waiting for your answer" }, total);
    else if (st === "paused") push({ k: "ev", ev: "you", label: "Paused by you", sub: "22 min ago" }, total);
    else if (st === "parked") push({ k: "ev", ev: "you", label: "Parked · waiting for model capacity", sub: m.name + " weekly limit" }, total);
    return { items, prn, hasPR: hist || frac >= 0.55, prState: hist ? (t.status === "failed" ? "closed" : "merged") : "open" };
  }
  const evHue = (o) => o.ev === "prog" ? Math.round(42 + o.pct * 1.03) : EVK[o.ev][0];
  function itemEl(o, m) {
    let h;
    if (o.k === "ev") h = '<div class="cv-ev' + (o.ev === "fail" || o.ev === "cmd" ? " bad" : o.ev === "you" ? " mute" : "") + '" style="--eh:' + evHue(o) + '"><span class="cv-evi">' + ic(EVK[o.ev][1]) + "</span><b>" + esc(o.label) + "</b>" + (o.sub ? '<span class="cv-evs">' + esc(o.sub) + "</span>" : "") + (o.go ? '<button type="button" class="cv-go" data-goto="' + o.go + '">Open</button>' : "") + "<time>" + fmtT(o.at) + "</time></div>";
    else if (o.k === "sys") h = '<div class="cv-sys">' + esc(o.text) + " · " + fmtD(o.at) + " " + fmtT(o.at) + "</div>";
    else if (o.k === "op") h = '<div class="cv-op"><p>' + esc(o.text) + "</p><time>You · " + fmtT(o.at) + "</time></div>";
    else if (o.k === "say") h = '<div class="cv-say"><img src="' + m.logo + '" alt=""><p>' + esc(o.text) + "</p></div>";
    else if (o.k === "tool") h = '<div class="cv-tool' + (o.bad ? " bad" : "") + '"><span class="cv-tn">' + MI.tool + o.name + "</span><code>" + esc(o.arg) + '</code><span class="cv-tr">' + esc(o.res) + "</span></div>";
    else h = '<div class="cv-diff"><div class="cv-dh"><code>' + esc(o.file) + '</code><span><b class="a">+' + o.add + '</b> <b class="d">−' + o.del + "</b></span></div><pre>" + o.lines.map((l) => '<span class="' + (l[0] === "+" ? "a" : l[0] === "-" ? "d" : "") + '">' + (l[0] === " " ? " " : l[0]) + " " + esc(l[1]) + "</span>").join("") + "</pre></div>";
    const w = document.createElement("div"); w.innerHTML = h; const el = w.firstChild;
    el.dataset.k = o.k === "ev" ? "ev" : o.k;
    if (o.k === "ev") { el.dataset.label = o.label; el.dataset.at = fmtT(o.at); el.dataset.ev = o.ev; }
    return el;
  }
  function descOf(t) {
    const r = rng(hash(t.id + "d")), e = D.epics[colKey(t)], low = t.title.charAt(0).toLowerCase() + t.title.slice(1);
    const shuf = (a) => a.map((x) => [r(), x]).sort((p, q) => p[0] - q[0]).map((p) => p[1]);
    const why = pick(r, ["Operators lose context when the daemon restarts mid-run, and this is one of the last gaps.", "Large repos with 10k+ events make the current behaviour slow and hard to reason about.", "This unblocks removing the " + (t.feature ? D.features[t.feature].label : e.label) + " feature flag.", "Reported twice this week; cheap to fix while the surrounding code is fresh."]);
    return {
      sum: "Implement " + low + ". " + why,
      scope: shuf(["Touch only the " + e.label.split(" · ")[0].toLowerCase() + " module and its tests", "Keep the public API unchanged", "Feature-flag anything user-visible", "Add a migration note if behaviour changes", "Reuse the existing retry and cursor helpers"]).slice(0, 3),
      done: shuf(["Tests cover empty, single-page and overflow cases", "No new lint or type errors", "Docs updated where behaviour changed", "p95 latency unchanged on the 10k-event fixture", "Works after a daemon restart"]).slice(0, 3),
    };
  }

  const MS = { t: null, timer: 0, rt: 0, log: null, map: null, mm: null, vw: null, s: 1, clock: 0, live: null };
  function stopLive() { clearTimeout(MS.timer); clearTimeout(MS.rt); MS.timer = MS.rt = 0; }
  function cleanupModal() { stopLive(); MS.t = null; MS.log = null; const m = $("#tk-modal"); if (m) m.classList.remove("bdm"); }

  function openModal(t) {
    if (!t) return;
    const back = $("#tk-backdrop"); if (!back) return;
    cleanupModal();
    MS.t = t;
    $("#tk-modal").classList.add("bdm");
    const m = t.agent ? MODELS[t.agent.model] : null, ag = t.sec === "now" ? AST[t.agent.state] : null, e = D.epics[colKey(t)];
    const cv = t.agent && t.start ? convo(t) : null;
    const fromDoc = t.sec === "plan" && t.wave >= 5;
    const stLabel = t.sec === "hist" ? (t.status === "failed" ? "Failed" : "Merged") : t.sec === "now" ? ag.label : t.sec === "plan" ? (fromDoc ? "Planned · not filed" : "Queued · Q" + t.qpos) : "Not queued";
    const tone = t.sec === "now" ? ag.cls : t.status === "failed" ? "stuck" : t.sec === "hist" ? "done" : "idle";
    const gh = "https://github.com/aiur-labs/aiur/";
    const live = t.sec === "now" && ["active", "paused"].includes(t.agent.state);
    $("#tk-head").innerHTML =
      '<div class="bm-h">' +
        '<span class="bm-ep" style="--h:' + e.hue + '" title="' + esc(e.label) + '">' + I[e.icon] + "</span>" +
        '<div class="bm-tt"><h3><span class="bm-num">#' + t.num + "</span>" + esc(t.title) + "</h3>" +
          '<div class="bm-meta"><span class="bm-st ' + tone + '"' + (t.sec === "now" ? ' style="--ph:' + Math.round(42 + t.pct * 1.03) + '"' : "") + "><i></i>" + stLabel + (t.sec === "now" ? ' · <b id="bm-pct">' + t.pct + "%</b>" : "") + "</span>" +
          "<span>" + esc(e.label) + "</span>" + (t.feature ? "<span>◆ " + esc(D.features[t.feature].label) + "</span>" : "") + "<span>" + t.pts + " pts</span></div></div>" +
        '<div class="bm-act">' +
          (m ? '<div class="bm-agent" title="' + m.full + " · " + t.agent.effort + ' effort"><img src="' + m.logo + '" alt=""><span>' + m.name + "</span>" +
            (live ? '<button class="bm-ib" type="button" data-a="pause" title="' + (t.agent.state === "paused" ? "Resume agent" : "Pause agent") + '">' + (t.agent.state === "paused" ? MI.play : MI.pause) + "</button>" : "") +
            (cv ? '<button class="bm-ib" type="button" data-a="chat" title="Open in Conversations">' + MI.expand + "</button>" : "") + "</div>" : "") +
          '<div class="bm-links">' +
            (fromDoc ? '<a class="bm-ib" href="#" data-a="none" title="From docs/build-plan.md · wave ' + t.wave + '">' + I.docs + "</a>" : '<a class="bm-ib" href="' + gh + "issues/" + t.num + '" target="_blank" rel="noopener" title="Issue #' + t.num + '">' + I.github + "</a>") +
            (cv && cv.hasPR ? '<a class="bm-pr ' + cv.prState + '" href="' + gh + "pull/" + cv.prn + '" target="_blank" rel="noopener" title="Pull request · ' + cv.prState + '">' + I.pr + "#" + cv.prn + "</a>" : "") +
            '<button class="bm-ib" type="button" data-a="link" title="Copy link">' + I.link + "</button>" +
          "</div>" +
          '<button class="bm-ib bm-x" id="bd-tk-close" type="button" aria-label="Close">' + I.x + "</button>" +
        "</div>" +
      "</div>";
    const body = $("#tk-body");
    if (cv) {
      const st = t.agent.state;
      const foot = t.sec === "hist"
        ? '<div class="cv-end">' + (t.status === "failed" ? "Session ended · PR closed " : "Session ended · merged ") + fmtD(t.end) + " " + fmtT(t.end) + "</div>"
        : (st === "command" ? '<div class="cv-cmd" id="bd-cmd"><p>Should in-flight retries be restored after a daemon restart, or stay process-local?</p><div class="row"><button class="btn sm" type="button" data-ans="Persist to disk, rehydrate on boot">Persist to disk, rehydrate on boot<span class="rec">recommended</span></button><button class="btn secondary sm" type="button" data-ans="Keep process-local">Keep process-local</button></div></div>' : "") +
          '<form class="cv-in" id="cv-in"><textarea rows="1" placeholder="' + (st === "paused" ? "Message the agent — it resumes when you send" : "Message " + m.name + "…") + '"></textarea>' +
          '<button class="cv-mic" type="button" id="cv-mic" title="Dictate" aria-label="Dictate">' + MI.mic + '</button><button class="cv-send" type="submit" aria-label="Send">' + MI.send + "</button></form>";
      body.innerHTML = '<div class="cv"><div class="cv-main"><div class="cv-log" id="cv-log"></div>' +
        '<button class="cv-new" type="button" id="cv-new" hidden>' + MI.down + "New activity</button>" +
        '<div class="cv-typing" id="cv-typing"' + (st === "active" && S.demo !== "offline" ? "" : " hidden") + "><i></i><i></i><i></i>" + m.name + " is working</div>" + foot + "</div>" +
        '<div class="cv-map" id="cv-map" title=""><div class="mm" id="cv-mm"></div><div class="mm-vw" id="cv-vw"></div><div class="mm-tip" id="cv-tip"></div></div></div>';
      MS.log = $("#cv-log"); MS.map = $("#cv-map"); MS.mm = $("#cv-mm"); MS.vw = $("#cv-vw");
      const frag = document.createDocumentFragment(); cv.items.forEach((o) => frag.appendChild(itemEl(o, m))); MS.log.appendChild(frag);
      MS.clock = cv.items.length ? cv.items[cv.items.length - 1].at : NOW;
      wireConvo(t, m);
    } else {
      const d = descOf(t), c = t.cue || {};
      const ups = t.deps.map((x) => D.byId[x]).filter(Boolean), downs = (D.children[t.id] || []).map((x) => D.byId[x]);
      const dep = (x) => '<button class="bm-dep" type="button" data-goto="' + x.id + '"><span style="--h:' + D.epics[colKey(x)].hue + '"></span>#' + x.num + "<em>" + esc(x.title) + "</em></button>";
      const fact = (k, v) => "<div><small>" + k + "</small><b>" + v + "</b></div>";
      const cues = [];
      if (c.held) cues.push('<p class="bm-cue">' + I.lock + esc(c.held) + "</p>");
      if (c.failed) cues.push('<p class="bm-cue bad">' + I.warn + "Prerequisite #" + c.failed.by + " failed — this and " + (c.failed.blocks.length - 1) + " more are blocked</p>");
      else if (c.wait) cues.push('<p class="bm-cue">' + I.hourglass + "Waiting on #" + c.wait + "</p>");
      if (t.override) cues.push('<p class="bm-cue">' + I.pencil + esc(t.override.reason) + "</p>");
      const who = pick(rng(hash(t.id)), CV.people);
      body.innerHTML = '<div class="bm-doc"><article class="bm-art">' +
        '<div class="bm-src">' + (fromDoc ? I.docs + "docs/build-plan.md · wave " + t.wave + " · not filed yet" : I.github + "#" + t.num + " · opened " + fmtD(t.created) + " by " + who) + "</div>" +
        '<p class="bm-sum">' + esc(d.sum) + "</p>" + cues.join("") +
        "<h4>Scope</h4><ul>" + d.scope.map((x) => "<li>" + esc(x) + "</li>").join("") + "</ul>" +
        "<h4>Done when</h4><ul>" + d.done.map((x) => "<li>" + esc(x) + "</li>").join("") + "</ul></article>" +
        '<aside class="bm-side"><div class="bm-facts">' +
          (t.sec === "plan" ? fact("Queue", "Q" + t.qpos) + fact("Wave", "W" + t.wave) : fact("Queue", "—")) +
          fact("Estimate", "≈" + (t.override ? t.override.hours : t.est || EST[t.cx - 1]) + "h") + fact("Complexity", t.cx + "/5") + "</div>" +
          (ups.length ? '<div class="bm-dg"><small>Depends on</small>' + ups.map(dep).join("") + "</div>" : "") +
          (downs.length ? '<div class="bm-dg"><small>Unblocks</small>' + downs.map(dep).join("") + "</div>" : "") +
          (t.sec === "nq" ? '<button class="btn secondary sm" type="button" data-a="none">' + I.up + " Add to queue</button>" : "") +
        "</aside></div>";
    }
    $("#bd-tk-close").addEventListener("click", closeModal);
    $$("[data-goto]", back).forEach((b) => b.addEventListener("click", () => openModal(D.byId[b.dataset.goto])));
    $$("[data-a]", $("#tk-head")).forEach((b) => b.addEventListener("click", (ev) => {
      const a = b.dataset.a, host = window.AiurHost || {};
      if (a === "none") { ev.preventDefault(); return; }
      if (a === "link") { (navigator.clipboard ? navigator.clipboard.writeText(location.href) : Promise.reject()).catch(() => {}); b.classList.add("ok"); b.title = "Copied"; return; }
      if (a === "pause") {
        const was = t.agent.state; t.agent.state = was === "paused" ? "active" : "paused"; refreshTicket(t);
        const sc = MS.log && MS.log.scrollTop; openModal(t); appendItem({ k: "ev", ev: was === "paused" ? "commit" : "you", label: was === "paused" ? "Resumed by you" : "Paused by you", sub: "just now" }); return;
      }
      if (a === "chat") { closeModal(); if (host.openConversation) host.openConversation((host.fleet || []).find((f) => f.id === t.id) || (host.fleet || [])[0]); }
    }));
    $$("[data-a]", body).forEach((b) => b.addEventListener("click", (ev) => ev.preventDefault()));
    back.classList.add("show"); document.body.style.overflow = "hidden";
    writeURL({ ticket: t.id });
  }

  function appendItem(o) {
    if (!MS.log || !MS.t) return;
    const log = MS.log, stick = log.scrollHeight - log.scrollTop - log.clientHeight < 60;
    MS.clock += 40000 + Math.random() * 60000; o.at = MS.clock;
    const el = itemEl(o, MODELS[MS.t.agent.model]); el.classList.add("in"); log.appendChild(el);
    if (stick) log.scrollTop = log.scrollHeight; else $("#cv-new").hidden = false;
    buildMap();
  }
  function wireConvo(t, m) {
    const log = MS.log, map = MS.map, tip = $("#cv-tip");
    requestAnimationFrame(() => { log.scrollTop = log.scrollHeight; buildMap(); });
    log.addEventListener("scroll", () => { syncView(); if (log.scrollHeight - log.scrollTop - log.clientHeight < 60) $("#cv-new").hidden = true; }, { passive: true });
    $("#cv-new").addEventListener("click", () => log.scrollTo({ top: log.scrollHeight, behavior: rmOn() ? "auto" : "smooth" }));
    const jump = (el) => { log.scrollTo({ top: Math.max(0, el.offsetTop - 16), behavior: rmOn() ? "auto" : "smooth" }); el.classList.remove("flash"); void el.offsetWidth; el.classList.add("flash"); };
    let drag = false;
    const toY = (ev) => { const r = map.getBoundingClientRect(), y = ev.clientY - r.top; log.scrollTop = y / MS.s - log.clientHeight / 2; };
    map.addEventListener("pointerdown", (ev) => { const e = ev.target.closest(".mm-e"); if (e) { jump(log.children[+e.dataset.i]); return; } drag = true; map.setPointerCapture(ev.pointerId); toY(ev); });
    map.addEventListener("pointermove", (ev) => {
      if (drag) { toY(ev); return; }
      const e = ev.target.closest(".mm-e");
      if (!e) { tip.classList.remove("show"); return; }
      const src = log.children[+e.dataset.i];
      tip.innerHTML = '<i style="--eh:' + e.style.getPropertyValue("--eh") + '"></i>' + esc(src.dataset.label) + "<time>" + src.dataset.at + "</time>";
      tip.style.top = e.offsetTop + "px"; tip.classList.add("show");
    });
    map.addEventListener("pointerup", () => { drag = false; });
    map.addEventListener("pointerleave", () => tip.classList.remove("show"));
    const form = $("#cv-in");
    if (form) {
      const ta = $("textarea", form);
      ta.addEventListener("input", () => { ta.style.height = "auto"; ta.style.height = Math.min(140, ta.scrollHeight) + "px"; });
      ta.addEventListener("keydown", (ev) => { if (ev.key === "Enter" && !ev.shiftKey) { ev.preventDefault(); form.requestSubmit(); } });
      $("#cv-mic").addEventListener("click", (ev) => ev.currentTarget.classList.toggle("rec"));
      form.addEventListener("submit", (ev) => {
        ev.preventDefault(); const v = ta.value.trim(); if (!v) return;
        ta.value = ""; ta.style.height = "auto";
        MS.log.scrollTop = MS.log.scrollHeight;
        appendItem({ k: "op", text: v });
        if (t.agent.state === "paused") { t.agent.state = "active"; refreshTicket(t); }
        clearTimeout(MS.rt); MS.rt = setTimeout(() => { appendItem({ k: "say", text: pick(Math.random, CV.replies) }); }, 1100);
        $("#cv-typing").hidden = false; startLive(t);
      });
    }
    $$("[data-ans]", $("#tk-body")).forEach((b) => b.addEventListener("click", () => {
      t.agent.state = "active"; refreshTicket(t);
      $("#bd-cmd").remove();
      appendItem({ k: "op", text: "Answered: " + b.dataset.ans });
      $("#cv-typing").hidden = false; startLive(t);
    }));
    startLive(t);
  }
  function startLive(t) {
    stopLive();
    if (t.sec !== "now" || t.agent.state !== "active" || S.demo === "offline") return;
    const r = Math.random; let n = 0;
    const step = () => {
      if (MS.t !== t) return;
      n++;
      if (n % 7 === 0) appendItem({ k: "ev", ev: "commit", label: "Commit " + sha(t.id + n + Date.now()), sub: pick(r, CV.commits) });
      else if (n % 4 === 0 && t.pct < 99) {
        const was = t.pct; t.pct = Math.min(99, t.pct + 1 + Math.floor(r() * 2));
        const pc = $("#bm-pct"); if (pc) pc.textContent = t.pct + "%";
        if (Math.floor(t.pct / 5) > Math.floor(was / 5)) appendItem({ k: "ev", ev: "prog", pct: t.pct, label: "Progress · " + t.pct + "%", sub: "reported by agent" });
        refreshTicket(t);
      } else appendItem(filler(r));
      MS.timer = setTimeout(step, rmOn() ? 3600 : 1600 + r() * 2200);
    };
    MS.timer = setTimeout(step, 1400);
  }
  function buildMap() {
    const log = MS.log, map = MS.map; if (!log || !map) return;
    const H0 = log.scrollHeight, rh = map.clientHeight, s = Math.min(0.14, rh / Math.max(1, H0));
    MS.s = s;
    let html = "";
    const kids = log.children;
    for (let i = 0; i < kids.length; i++) {
      const el = kids[i], k = el.dataset.k, top = (el.offsetTop * s).toFixed(1);
      if (k === "ev") html += '<button type="button" class="mm-e' + (el.classList.contains("bad") ? " bad" : "") + '" data-i="' + i + '" style="top:' + top + "px;--eh:" + el.style.getPropertyValue("--eh") + '" aria-label="' + esc(el.dataset.label) + '"></button>';
      else { const h = Math.max(1.5, el.offsetHeight * s - 1.5).toFixed(1), w = k === "say" ? 62 + (i * 37 % 30) : k === "tool" ? 42 + (i * 23 % 24) : k === "op" ? 46 : k === "sys" ? 36 : 84; html += '<i class="mm-b k-' + k + '" style="top:' + top + "px;height:" + h + "px;width:" + w + '%"></i>'; }
    }
    MS.mm.innerHTML = html; MS.mm.style.height = (H0 * s) + "px";
    syncView();
  }
  function syncView() { if (!MS.log || !MS.vw) return; MS.vw.style.top = (MS.log.scrollTop * MS.s) + "px"; MS.vw.style.height = Math.max(8, MS.log.clientHeight * MS.s) + "px"; }
  function closeModal() { const b = $("#tk-backdrop"); if (b) b.classList.remove("show"); document.body.style.overflow = ""; cleanupModal(); }
  function refreshTicket(t) {
    if (!L) return;
    L.band.items.forEach((it) => { if (it.t === t) { const n = makeCard(it); n.classList.add("noanim"); it.el.replaceWith(n); it.el = n; place(n, it); } });
    drawEdgesSoon(30);
  }

  /* ============================================================ API */
  function init() {
    readURL();
    shell();
    D = dataFor(S.demo);
    wireUsagePop();
    window.addEventListener("resize", () => { if (MS.log) buildMap(); });
    const back = $("#tk-backdrop");
    if (back) new MutationObserver(() => { if (!back.classList.contains("show")) { if (MS.t) cleanupModal(); if (new URLSearchParams(location.search).get("ticket")) writeURL({ ticket: "" }); } }).observe(back, { attributes: true, attributeFilter: ["class"] });
  }
  window.AiurBuild = {
    render() {
      if (!root) init();
      if (!inited) {
        inited = true;
        renderAll();
        loadingTimer = setTimeout(() => {
          S.loading = false; viewport(); relayout();
          jumpNow(true); S.ready = true;
          requestAnimationFrame(() => {
            const tk = new URLSearchParams(location.search).get("ticket");
            if (tk && D.byId[tk]) openModal(D.byId[tk]);
          });
        }, 600);
      } else if (!S.loading) { relayout(); update(); }
    },
    open: (id) => openModal(D && D.byId[id]),
  };
})();
