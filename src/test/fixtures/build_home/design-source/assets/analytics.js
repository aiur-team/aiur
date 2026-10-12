/* ============================================================
   AIUR — RUN ANALYTICS
   Live utilization / concurrency / per-ticket strain view.
   Bespoke D3 charts (same library family as the reference
   artifact). Binds to the same ticket model as the rest of the
   dashboard (window.__aiurFleet); telemetry is derived per-ticket
   so every chart reflects the real fleet.
   ============================================================ */
(function () {
  "use strict";

  var NOW = 107;          // minutes elapsed in the current run
  var STEP = 1;           // sample cadence (min)
  var CAP = 20;           // max-agents cap
  var CORES = 100;        // CPU ceiling expressed as % of machine
  var HOST_MEM = 32;      // host memory ceiling (GB)

  var timeDomain = [0, NOW]; // shared zoom window across all time charts

  var EPIC_COLOR = { docs: "#c69bff", frontend: "#2f86ff", backend: "#4fd6c4", infra: "#f0883e" };
  var EPIC_LABEL = { docs: "Docs", frontend: "Front end", backend: "Back end", infra: "Infra" };
  var EXEC_COLOR = "#9aa2ad";

  /* ---- deterministic PRNG (mulberry32) ---- */
  function rng(seed) {
    return function () {
      seed |= 0; seed = (seed + 0x6D2B79F5) | 0;
      var t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function cssVar(n) { return getComputedStyle(document.documentElement).getPropertyValue(n).trim(); }
  function parseMin(s) {
    if (!s) return 0;
    var h = /(\d+)\s*h/.exec(s), m = /(\d+)\s*m/.exec(s);
    return (h ? +h[1] * 60 : 0) + (m ? +m[1] : 0);
  }
  function fmtElapsed(min) {
    var h = Math.floor(min / 60), m = Math.round(min % 60);
    return h > 0 ? h + "h" + (m ? " " + m + "m" : "") : m + "m";
  }
  function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }

  var ACTIVE_KINDS = { working: 1, brainstorm: 1, retry: 1, blocked: 1, paused: 1 };

  /* ---- derive per-ticket lifecycle + resource profile ---- */
  var MODEL = null;
  function buildModel() {
    if (MODEL) return MODEL;
    var fleet = (window.__aiurFleet || []).map(function (f) { return f; });
    var agentBonus = { opus: 1.5, sonnet: 0.7, codex: 0.5 };

    var tickets = fleet.map(function (f) {
      var r = rng(f.num);
      var active = parseMin(f.runtime) || (f.complexity * 6);
      var finished = f.phaseKind === "finished";
      var isActive = !!ACTIVE_KINDS[f.phaseKind];
      var queued = f.phaseKind === "queued";
      var coreLoad = 3 + f.complexity * 1.15 + (agentBonus[f.agent] || 0.6) + r() * 1.2; // % of machine
      var memLoad = 0.55 + f.complexity * 0.42 + (agentBonus[f.agent] || 0.6) * 0.35 + r() * 0.4; // GB

      var start = null, ipEnd = null, reviewEnd = null, queuedAt, merged = null, stallAt = null;
      if (finished) {
        var phaseStart = (f.phase - 1) * 13 + r() * 5;
        start = clamp(phaseStart, 0, NOW - 8);
        ipEnd = Math.min(start + active, NOW - 4);
        reviewEnd = Math.min(ipEnd + 2.5 + r() * 2, NOW - 1);
        merged = reviewEnd;
        queuedAt = Math.max(0, start - (2 + r() * 4));
      } else if (isActive) {
        start = clamp(NOW - active, 0, NOW - 1);
        ipEnd = NOW;
        queuedAt = Math.max(0, start - (2 + r() * 4));
        if (f.phaseKind === "blocked" || f.phaseKind === "paused" || f.phaseKind === "retry") {
          stallAt = clamp(NOW - active * (0.25 + r() * 0.2), start + 1, NOW - 1);
        }
      } else { // queued
        queuedAt = clamp((f.phase - 1) * 15 + r() * 6, 0, NOW);
      }

      // CPU-seconds cost = coreLoad(%)/100 * cores-equiv * duration; keep as %·min → CPU-min, x60 = CPU-s
      var dur = (finished ? (ipEnd - start) : isActive ? (start != null ? NOW - start : 0) : 0);
      var cpuSeconds = Math.round((coreLoad / 100) * 8 * dur * 60); // 8 logical cores machine
      var peakCPU = +(coreLoad * (1.3 + r() * 0.3)).toFixed(1);
      var peakMem = +(memLoad * (1.25 + r() * 0.25)).toFixed(2);

      return {
        id: f.id, num: f.num, title: f.title, epic: f.epic, phase: f.phase,
        complexity: f.complexity, agent: f.agent, kind: f.phaseKind, pct: f.pct,
        finished: finished, isActive: isActive, queued: queued,
        start: start, ipEnd: ipEnd, reviewEnd: reviewEnd, merged: merged,
        queuedAt: queuedAt, stallAt: stallAt, active: active,
        coreLoad: coreLoad, memLoad: memLoad,
        cpuSeconds: cpuSeconds, peakCPU: peakCPU, peakMem: peakMem,
        color: EPIC_COLOR[f.epic] || "#8a929e"
      };
    });

    // agents that ever ran (have a start) — the stackable series
    var agents = tickets.filter(function (t) { return t.start != null; });

    // time series
    var series = [];
    for (var t = 0; t <= NOW; t += STEP) {
      var execCPU = 7 + Math.sin(t / 9) * 1.6 + 1.2;
      var execMem = 1.6 + Math.sin(t / 13) * 0.25;
      var totCPU = execCPU, totMem = execMem, conc = 0;
      var perAgent = {};
      agents.forEach(function (a) {
        var on = t >= a.start && t <= a.ipEnd;
        if (a.stallAt != null && t > a.stallAt) on = a.kind === "retry" ? (Math.sin(t) > 0.4) : false; // stalled agents mostly idle
        if (on) {
          var jr = rng(a.num * 97 + Math.floor(t)); var n = jr();
          var cpu = a.coreLoad * (0.8 + n * 0.4);
          var mem = a.memLoad * (0.9 + n * 0.2);
          perAgent[a.id] = cpu;
          totCPU += cpu; totMem += mem; conc++;
        } else { perAgent[a.id] = 0; }
      });
      series.push({ t: t, execCPU: execCPU, execMem: execMem, cpu: totCPU, mem: totMem, conc: conc, per: perAgent });
    }

    // KPIs
    var peakConc = 0, concNow = series[series.length - 1].conc, utilSum = 0, waste = 0;
    series.forEach(function (s) {
      peakConc = Math.max(peakConc, s.conc);
      utilSum += s.cpu / CORES;
      waste += (CAP - s.conc) * STEP;
    });
    var meanUtil = Math.round((utilSum / series.length) * 100);
    var memNow = series[series.length - 1].mem;
    var memHeadroom = Math.round((1 - memNow / HOST_MEM) * 100);
    var merged = tickets.filter(function (t) { return t.finished; });
    var wasteHrs = +(waste / 60).toFixed(1);

    MODEL = {
      tickets: tickets, agents: agents, series: series,
      kpi: {
        peakConc: peakConc, concNow: concNow, meanUtil: meanUtil,
        memHeadroom: memHeadroom, memNow: memNow.toFixed(1),
        merged: merged.length, done: merged.length, total: tickets.length,
        waste: wasteHrs
      }
    };
    return MODEL;
  }

  /* ---- shared selection ---- */
  var selected = null; // Set of ticket ids (agents)
  function initSelection(m) {
    if (selected) return;
    selected = new Set(m.agents.map(function (a) { return a.id; }));
  }
  function isSel(id) { return selected.has(id); }

  /* ============================================================
     CHART HELPERS
     ============================================================ */
  function pal() {
    return {
      fg: cssVar("--fg"), muted: cssVar("--muted"), faint: cssVar("--faint"),
      line: cssVar("--line"), hair: cssVar("--hairline"), surf: cssVar("--surface-2"),
      accent: cssVar("--accent"), block: cssVar("--block"), good: cssVar("--good"),
      attn: cssVar("--attn")
    };
  }
  var MONO = '"JetBrains Mono", monospace';
  function svgIn(sel, w, h) {
    d3.select(sel).selectAll("svg").remove();
    return d3.select(sel).append("svg").attr("width", w).attr("height", h)
      .attr("viewBox", "0 0 " + w + " " + h).style("display", "block").style("width", "100%");
  }
  function axisStyle(g, p) {
    g.selectAll("text").attr("fill", p.muted).style("font-family", MONO).style("font-size", "10px");
    g.selectAll("line").attr("stroke", p.hair);
    g.selectAll(".domain").attr("stroke", p.line);
  }
  function xTicks(scale) {
    return d3.axisBottom(scale).ticks(6).tickFormat(function (d) { return fmtElapsed(d); }).tickSize(-4);
  }
  function tdFilter(t) { return t >= timeDomain[0] - STEP && t <= timeDomain[1] + STEP; }
  function addBrush(svg, x, iw, ih, yr) {
    var p = pal();
    var y0 = yr ? yr[0] : 0, y1 = yr ? yr[1] : ih;
    var brush = d3.brushX().extent([[0, y0], [iw, y1]]).on("end", function (e) {
      if (!e.selection) return;
      var d0 = x.invert(e.selection[0]), d1 = x.invert(e.selection[1]);
      svg.select(".an-brush").call(brush.move, null);
      if (d1 - d0 < 2) return;
      timeDomain = [Math.max(0, d0), Math.min(NOW, d1)];
      rerenderTime();
    });
    var g = svg.append("g").attr("class", "an-brush").call(brush);
    g.select(".selection").attr("fill", p.accent).attr("fill-opacity", 0.14).attr("stroke", p.accent).attr("stroke-opacity", 0.5);
    g.selectAll(".handle").attr("fill", p.accent).attr("fill-opacity", 0.5);
  }

  /* ---------- 1. per-actor CPU (stacked area) — the anchor ---------- */
  function chartCPU(el, m) {
    var p = pal(), W = el.clientWidth || 640, H = 300;
    var mg = { t: 14, r: 14, b: 26, l: 40 };
    var iw = W - mg.l - mg.r, ih = H - mg.t - mg.b;
    var svg = svgIn(el, W, H).append("g").attr("transform", "translate(" + mg.l + "," + mg.t + ")");
    var x = d3.scaleLinear().domain(timeDomain).range([0, iw]);
    // series keys: executor + selected agents, ordered by pickup
    var ags = m.agents.filter(function (a) { return isSel(a.id); }).sort(function (a, b) { return a.start - b.start; });
    var keys = ["__exec"].concat(ags.map(function (a) { return a.id; }));
    var rows = m.series.filter(function (s) { return tdFilter(s.t); }).map(function (s) {
      var o = { t: s.t, __exec: s.execCPU };
      ags.forEach(function (a) { o[a.id] = s.per[a.id] || 0; });
      return o;
    });
    var stack = d3.stack().keys(keys)(rows);
    var maxY = Math.max(CORES, d3.max(stack[stack.length - 1], function (d) { return d[1]; }) || 0);
    var y = d3.scaleLinear().domain([0, maxY]).range([ih, 0]);
    var area = d3.area().x(function (d) { return x(d.data.t); }).y0(function (d) { return y(d[0]); }).y1(function (d) { return y(d[1]); }).curve(d3.curveBasis);

    // ceiling line (CPU machine 100%)
    svg.append("line").attr("x1", 0).attr("x2", iw).attr("y1", y(CORES)).attr("y2", y(CORES))
      .attr("stroke", p.block).attr("stroke-width", 1).attr("stroke-dasharray", "4 3").attr("opacity", 0.7);
    svg.append("text").attr("x", iw).attr("y", y(CORES) - 5).attr("text-anchor", "end")
      .attr("fill", p.block).style("font-family", MONO).style("font-size", "9px").text("machine ceiling 100%");

    svg.selectAll("path.lyr").data(stack).enter().append("path").attr("class", "lyr")
      .attr("d", area)
      .attr("fill", function (d) { return d.key === "__exec" ? EXEC_COLOR : (m.agents.find(function (a) { return a.id === d.key; }) || {}).color; })
      .attr("fill-opacity", function (d) { return d.key === "__exec" ? 0.55 : 0.82; })
      .attr("stroke", cssVar("--surface")).attr("stroke-width", 0.4);

    var gx = svg.append("g").attr("transform", "translate(0," + ih + ")").call(xTicks(x)); axisStyle(gx, p);
    var gy = svg.append("g").call(d3.axisLeft(y).ticks(4).tickFormat(function (d) { return d + "%"; }).tickSize(-iw)); axisStyle(gy, p);
    // now marker
    nowLine(svg, x, ih, p, iw);
  }

  function nowLine(svg, x, ih, p, iw, noBrush) {
    if (iw != null && !noBrush) addBrush(svg, x, iw, ih);
    if (NOW < timeDomain[0] || NOW > timeDomain[1]) return;
    svg.append("line").attr("x1", x(NOW)).attr("x2", x(NOW)).attr("y1", 0).attr("y2", ih)
      .attr("stroke", p.fg).attr("stroke-width", 1).attr("opacity", 0.35);
    svg.append("text").attr("x", x(NOW) - 4).attr("y", 10).attr("text-anchor", "end")
      .attr("fill", p.muted).style("font-family", MONO).style("font-size", "9px").text("now");
  }

  /* ---------- 2. concurrency vs cap ---------- */
  function chartConc(el, m) {
    var p = pal(), W = el.clientWidth || 640, H = 250;
    var mg = { t: 16, r: 14, b: 26, l: 34 };
    var iw = W - mg.l - mg.r, ih = H - mg.t - mg.b;
    var svg = svgIn(el, W, H).append("g").attr("transform", "translate(" + mg.l + "," + mg.t + ")");
    var x = d3.scaleLinear().domain(timeDomain).range([0, iw]);
    var y = d3.scaleLinear().domain([0, CAP]).range([ih, 0]);
    var data = m.series.filter(function (s) { return tdFilter(s.t); }).map(function (s) {
      var c = 0; m.agents.forEach(function (a) { if (isSel(a.id) && s.per[a.id] > 0) c++; });
      return { t: s.t, conc: c };
    });
    // wasted headroom = area between cap and concurrency
    var areaGap = d3.area().x(function (d) { return x(d.t); }).y0(y(CAP)).y1(function (d) { return y(d.conc); }).curve(d3.curveStepAfter);
    svg.append("path").datum(data).attr("d", areaGap).attr("fill", p.block).attr("fill-opacity", 0.08);
    // cap line
    svg.append("line").attr("x1", 0).attr("x2", iw).attr("y1", y(CAP)).attr("y2", y(CAP))
      .attr("stroke", p.attn).attr("stroke-width", 1.2).attr("stroke-dasharray", "5 3");
    svg.append("text").attr("x", 2).attr("y", y(CAP) - 5).attr("fill", p.attn)
      .style("font-family", MONO).style("font-size", "9px").text("cap " + CAP);
    // concurrency area + line
    var areaC = d3.area().x(function (d) { return x(d.t); }).y0(ih).y1(function (d) { return y(d.conc); }).curve(d3.curveStepAfter);
    svg.append("path").datum(data).attr("d", areaC).attr("fill", p.accent).attr("fill-opacity", 0.16);
    var lineC = d3.line().x(function (d) { return x(d.t); }).y(function (d) { return y(d.conc); }).curve(d3.curveStepAfter);
    svg.append("path").datum(data).attr("d", lineC).attr("fill", "none").attr("stroke", p.accent).attr("stroke-width", 1.8);
    var gx = svg.append("g").attr("transform", "translate(0," + ih + ")").call(xTicks(x)); axisStyle(gx, p);
    var gy = svg.append("g").call(d3.axisLeft(y).ticks(5).tickSize(-iw)); axisStyle(gy, p);
    nowLine(svg, x, ih, p, iw);
  }

  /* ---------- 3. memory over run ---------- */
  function chartMem(el, m) {
    var p = pal(), W = el.clientWidth || 640, H = 250;
    var mg = { t: 16, r: 14, b: 26, l: 40 };
    var iw = W - mg.l - mg.r, ih = H - mg.t - mg.b;
    var svg = svgIn(el, W, H).append("g").attr("transform", "translate(" + mg.l + "," + mg.t + ")");
    var x = d3.scaleLinear().domain(timeDomain).range([0, iw]);
    var y = d3.scaleLinear().domain([0, HOST_MEM]).range([ih, 0]);
    var data = m.series.filter(function (s) { return tdFilter(s.t); }).map(function (s) {
      var mem = s.execMem; m.agents.forEach(function (a) { if (isSel(a.id) && s.per[a.id] > 0) mem += a.memLoad; });
      return { t: s.t, mem: mem };
    });
    var area = d3.area().x(function (d) { return x(d.t); }).y0(ih).y1(function (d) { return y(d.mem); }).curve(d3.curveBasis);
    svg.append("path").datum(data).attr("d", area).attr("fill", p.good).attr("fill-opacity", 0.14);
    var line = d3.line().x(function (d) { return x(d.t); }).y(function (d) { return y(d.mem); }).curve(d3.curveBasis);
    svg.append("path").datum(data).attr("d", line).attr("fill", "none").attr("stroke", p.good).attr("stroke-width", 1.8);
    svg.append("line").attr("x1", 0).attr("x2", iw).attr("y1", y(HOST_MEM)).attr("y2", y(HOST_MEM))
      .attr("stroke", p.block).attr("stroke-width", 1).attr("stroke-dasharray", "4 3").attr("opacity", 0.8);
    svg.append("text").attr("x", iw).attr("y", y(HOST_MEM) + 12).attr("text-anchor", "end").attr("fill", p.block)
      .style("font-family", MONO).style("font-size", "9px").text("host " + HOST_MEM + " GB");
    var gx = svg.append("g").attr("transform", "translate(0," + ih + ")").call(xTicks(x)); axisStyle(gx, p);
    var gy = svg.append("g").call(d3.axisLeft(y).ticks(4).tickFormat(function (d) { return d + "G"; }).tickSize(-iw)); axisStyle(gy, p);
    nowLine(svg, x, ih, p, iw);
  }

  /* ---------- 4. ticket gantt / waterfall ---------- */
  function chartGantt(el, m) {
    var p = pal(), W = el.clientWidth || 640;
    var rowH = 17, mg = { t: 22, r: 14, b: 4, l: 66 };
    var rows = m.tickets.slice().sort(function (a, b) {
      var sa = a.start != null ? a.start : a.queuedAt + 1000, sb = b.start != null ? b.start : b.queuedAt + 1000;
      return sa - sb;
    });
    var ih = rows.length * rowH;
    var H = ih + mg.t + mg.b;
    var iw = W - mg.l - mg.r;
    var svg = svgIn(el, W, H).append("g").attr("transform", "translate(" + mg.l + "," + mg.t + ")");
    var x = d3.scaleLinear().domain(timeDomain).range([0, iw]);
    // gridlines
    x.ticks(6).forEach(function (t) {
      svg.append("line").attr("x1", x(t)).attr("x2", x(t)).attr("y1", -6).attr("y2", ih).attr("stroke", p.hair);
      svg.append("text").attr("x", x(t)).attr("y", -10).attr("text-anchor", "middle").attr("fill", p.muted)
        .style("font-family", MONO).style("font-size", "9px").text(fmtElapsed(t));
    });
    var g = svg.selectAll("g.row").data(rows).enter().append("g").attr("class", "row")
      .attr("transform", function (d, i) { return "translate(0," + (i * rowH) + ")"; })
      .style("cursor", "pointer").attr("opacity", function (d) { return d.start == null || isSel(d.id) ? 1 : 0.9; })
      .on("click", function (e, d) { if (window.__aiurOpenTicket) window.__aiurOpenTicket(d.id); });
    // label
    g.append("text").attr("x", -mg.l + 2).attr("y", rowH / 2 + 3).attr("fill", function (d) { return (d.start != null && !isSel(d.id)) ? p.faint : p.muted; })
      .style("font-family", MONO).style("font-size", "9.5px").text(function (d) { return d.num; });
    var bh = rowH - 6, by = 3;
    // queued (wait) segment
    g.append("rect").attr("x", function (d) { return x(d.queuedAt); }).attr("y", by + bh / 2 - 1.5)
      .attr("width", function (d) { var end = d.start != null ? d.start : NOW; return Math.max(0, x(end) - x(d.queuedAt)); })
      .attr("height", 3).attr("rx", 1.5).attr("fill", p.faint).attr("opacity", 0.4);
    // in-progress segment
    g.append("rect").filter(function (d) { return d.start != null; }).attr("x", function (d) { return x(d.start); })
      .attr("y", by).attr("width", function (d) { return Math.max(2, x(d.ipEnd) - x(d.start)); }).attr("height", bh)
      .attr("rx", 3).attr("fill", function (d) { return d.color; })
      .attr("fill-opacity", function (d) { return isSel(d.id) ? 0.9 : 0.25; });
    // review segment (finished)
    g.append("rect").filter(function (d) { return d.finished; }).attr("x", function (d) { return x(d.ipEnd); })
      .attr("y", by).attr("width", function (d) { return Math.max(2, x(d.reviewEnd) - x(d.ipEnd)); }).attr("height", bh)
      .attr("rx", 2).attr("fill", function (d) { return d.color; }).attr("fill-opacity", function (d) { return isSel(d.id) ? 0.4 : 0.15; });
    // end marker
    g.append("circle").filter(function (d) { return d.start != null; })
      .attr("cx", function (d) { return x(d.finished ? d.reviewEnd : d.ipEnd); }).attr("cy", by + bh / 2).attr("r", 3)
      .attr("fill", function (d) {
        return d.finished ? p.good : d.kind === "blocked" ? p.block : d.kind === "paused" ? p.faint : d.kind === "retry" ? p.attn : p.accent;
      }).attr("stroke", cssVar("--surface")).attr("stroke-width", 1);
    nowLine(svg, x, ih, p);
    addBrush(svg, x, iw, ih, [-mg.t + 2, -2]);
  }

  /* ---------- 5. cost-per-ticket (ranked bars) ---------- */
  var costSort = "cpu";
  function chartCost(el, m) {
    var p = pal(), W = el.clientWidth || 640;
    var mg = { t: 6, r: 54, b: 6, l: 66 };
    var data = m.tickets.filter(function (t) { return t.start != null && isSel(t.id); });
    data.sort(function (a, b) {
      return costSort === "cpu" ? b.cpuSeconds - a.cpuSeconds : costSort === "mem" ? b.peakMem - a.peakMem : b.peakCPU - a.peakCPU;
    });
    var rowH = 22, ih = data.length * rowH, H = ih + mg.t + mg.b, iw = W - mg.l - mg.r;
    var svg = svgIn(el, W, H).append("g").attr("transform", "translate(" + mg.l + "," + mg.t + ")");
    var valOf = function (d) { return costSort === "cpu" ? d.cpuSeconds : costSort === "mem" ? d.peakMem : d.peakCPU; };
    var max = d3.max(data, valOf) || 1;
    var x = d3.scaleLinear().domain([0, max]).range([0, iw]);
    var g = svg.selectAll("g.b").data(data).enter().append("g").attr("class", "b")
      .attr("transform", function (d, i) { return "translate(0," + (i * rowH) + ")"; })
      .style("cursor", "pointer").on("click", function (e, d) { if (window.__aiurOpenTicket) window.__aiurOpenTicket(d.id); });
    g.append("text").attr("x", -mg.l + 2).attr("y", rowH / 2 + 3).attr("fill", p.muted)
      .style("font-family", MONO).style("font-size", "9.5px").text(function (d) { return d.num; });
    g.append("rect").attr("x", 0).attr("y", 3).attr("height", rowH - 8).attr("rx", 3)
      .attr("width", function (d) { return Math.max(2, x(valOf(d))); }).attr("fill", function (d) { return d.color; }).attr("fill-opacity", 0.85);
    g.append("text").attr("x", function (d) { return x(valOf(d)) + 6; }).attr("y", rowH / 2 + 3).attr("fill", p.fg)
      .style("font-family", MONO).style("font-size", "9.5px")
      .text(function (d) { return costSort === "cpu" ? (d.cpuSeconds + "s") : costSort === "mem" ? (d.peakMem + "G") : (d.peakCPU + "%"); });
  }

  /* ---------- 6. burn-up ---------- */
  function chartBurn(el, m) {
    var p = pal(), W = el.clientWidth || 640, H = 250;
    var mg = { t: 16, r: 40, b: 26, l: 30 };
    var iw = W - mg.l - mg.r, ih = H - mg.t - mg.b;
    var svg = svgIn(el, W, H).append("g").attr("transform", "translate(" + mg.l + "," + mg.t + ")");
    var x = d3.scaleLinear().domain(timeDomain).range([0, iw]);
    var total = m.tickets.length;
    var y = d3.scaleLinear().domain([0, total]).range([ih, 0]);
    var mergeTimes = m.tickets.filter(function (t) { return t.finished; }).map(function (t) { return t.merged; }).sort(d3.ascending);
    var data = [];
    for (var t = 0; t <= NOW; t += STEP) {
      var done = mergeTimes.filter(function (mt) { return mt <= t; }).length;
      data.push({ t: t, done: done });
    }
    data = data.filter(function (d) { return tdFilter(d.t); });
    // scope (total) line
    svg.append("line").attr("x1", 0).attr("x2", iw).attr("y1", y(total)).attr("y2", y(total))
      .attr("stroke", p.muted).attr("stroke-width", 1).attr("stroke-dasharray", "5 3").attr("opacity", 0.6);
    svg.append("text").attr("x", iw).attr("y", y(total) - 5).attr("text-anchor", "end").attr("fill", p.muted)
      .style("font-family", MONO).style("font-size", "9px").text("scope " + total);
    var area = d3.area().x(function (d) { return x(d.t); }).y0(ih).y1(function (d) { return y(d.done); }).curve(d3.curveStepAfter);
    svg.append("path").datum(data).attr("d", area).attr("fill", p.good).attr("fill-opacity", 0.15);
    var line = d3.line().x(function (d) { return x(d.t); }).y(function (d) { return y(d.done); }).curve(d3.curveStepAfter);
    svg.append("path").datum(data).attr("d", line).attr("fill", "none").attr("stroke", p.good).attr("stroke-width", 2);
    // end label
    var last = data[data.length - 1];
    svg.append("text").attr("x", x(last.t) + 5).attr("y", y(last.done) + 3).attr("fill", p.good)
      .style("font-family", MONO).style("font-size", "10px").style("font-weight", 700).text(last.done);
    var gx = svg.append("g").attr("transform", "translate(0," + ih + ")").call(xTicks(x)); axisStyle(gx, p);
    var gy = svg.append("g").call(d3.axisLeft(y).ticks(5).tickSize(-iw)); axisStyle(gy, p);
    nowLine(svg, x, ih, p, iw);
  }

  /* ---------- 7. complexity breakdown ---------- */
  function chartComplexity(el, m) {
    var p = pal(), W = el.clientWidth || 640, H = 220;
    var mg = { t: 14, r: 16, b: 40, l: 34 };
    var iw = W - mg.l - mg.r, ih = H - mg.t - mg.b;
    var svg = svgIn(el, W, H).append("g").attr("transform", "translate(" + mg.l + "," + mg.t + ")");
    var tiers = d3.groups(m.tickets, function (t) { return t.complexity; }).map(function (grp) {
      var arr = grp[1];
      var withCpu = arr.filter(function (t) { return t.cpuSeconds > 0; });
      return {
        c: grp[0], count: arr.length,
        avgCpu: withCpu.length ? Math.round(d3.mean(withCpu, function (t) { return t.cpuSeconds; })) : 0,
        avgWall: withCpu.length ? Math.round(d3.mean(withCpu, function (t) { return t.active; })) : 0
      };
    }).sort(function (a, b) { return a.c - b.c; });
    var x = d3.scaleBand().domain(tiers.map(function (d) { return d.c; })).range([0, iw]).padding(0.35);
    var y = d3.scaleLinear().domain([0, d3.max(tiers, function (d) { return d.count; })]).nice().range([ih, 0]);
    var g = svg.selectAll("g.c").data(tiers).enter().append("g").attr("class", "c").attr("transform", function (d) { return "translate(" + x(d.c) + ",0)"; });
    g.append("rect").attr("y", function (d) { return y(d.count); }).attr("width", x.bandwidth()).attr("height", function (d) { return ih - y(d.count); })
      .attr("rx", 4).attr("fill", p.accent).attr("fill-opacity", 0.8);
    g.append("text").attr("x", x.bandwidth() / 2).attr("y", function (d) { return y(d.count) - 6; }).attr("text-anchor", "middle")
      .attr("fill", p.fg).style("font-family", MONO).style("font-size", "11px").style("font-weight", 700).text(function (d) { return d.count; });
    // tier label + avgs
    g.append("text").attr("x", x.bandwidth() / 2).attr("y", ih + 15).attr("text-anchor", "middle").attr("fill", p.muted)
      .style("font-family", MONO).style("font-size", "9.5px").text(function (d) { return "C" + d.c; });
    g.append("text").attr("x", x.bandwidth() / 2).attr("y", ih + 28).attr("text-anchor", "middle").attr("fill", p.faint)
      .style("font-family", MONO).style("font-size", "8.5px").text(function (d) { return d.avgWall ? "~" + fmtElapsed(d.avgWall) : "—"; });
    var gy = svg.append("g").call(d3.axisLeft(y).ticks(4).tickSize(-iw)); axisStyle(gy, p);
  }

  /* ============================================================
     KPI STRIP + LEGEND + LAYOUT
     ============================================================ */
  function kpiStrip(m) {
    var k = m.kpi;
    var items = [
      { label: "Peak concurrency", val: k.peakConc, sub: k.concNow + " now / " + CAP + " cap" },
      { label: "Mean utilization", val: k.meanUtil + "%", sub: "machine CPU" },
      { label: "Memory headroom", val: k.memHeadroom + "%", sub: k.memNow + " / " + HOST_MEM + " GB" },
      { label: "PRs merged", val: k.merged, sub: "this run" },
      { label: "Tickets done", val: k.done + " / " + k.total, sub: Math.round(k.done / k.total * 100) + "% complete" },
      { label: "Wasted capacity", val: k.waste + "h", sub: "idle unit-slots", tone: "block" }
    ];
    return '<div class="an-kpis">' + items.map(function (it) {
      return '<div class="an-kpi' + (it.tone ? " " + it.tone : "") + '">' +
        '<span class="an-kpi-label">' + it.label + '</span>' +
        '<span class="an-kpi-val">' + it.val + '</span>' +
        '<span class="an-kpi-sub">' + it.sub + '</span></div>';
    }).join("") + '</div>';
  }

  function legend(m) {
    var byEpic = d3.groups(m.agents, function (a) { return a.epic; });
    var order = ["docs", "frontend", "backend", "infra"];
    byEpic.sort(function (a, b) { return order.indexOf(a[0]) - order.indexOf(b[0]); });
    var html = '<div class="an-legend"><div class="an-legend-head">' +
      '<span class="an-legend-title">Tickets</span>' +
      '<div class="an-legend-acts"><button class="an-lg-btn" data-lg="all">All</button><button class="an-lg-btn" data-lg="none">None</button></div></div>' +
      '<div class="an-legend-groups">';
    byEpic.forEach(function (grp) {
      html += '<div class="an-lg-group"><span class="an-lg-gtitle" style="color:' + EPIC_COLOR[grp[0]] + '">' + EPIC_LABEL[grp[0]] + '</span><div class="an-lg-chips">';
      grp[1].sort(function (a, b) { return a.num - b.num; }).forEach(function (a) {
        html += '<button class="an-chip' + (isSel(a.id) ? " on" : "") + '" data-tid="' + a.id + '" title="' + a.title.replace(/"/g, "") + '">' +
          '<i style="background:' + a.color + '"></i>' + a.num + '</button>';
      });
      html += '</div></div>';
    });
    html += '</div></div>';
    return html;
  }

  function renderAll(root, m) {
    var map = {
      "#an-cpu": chartCPU, "#an-conc": chartConc, "#an-mem": chartMem,
      "#an-gantt": chartGantt, "#an-cost": chartCost, "#an-burn": chartBurn, "#an-cx": chartComplexity
    };
    Object.keys(map).forEach(function (sel) {
      var el = root.querySelector(sel);
      if (el) { try { map[sel](el, m); } catch (e) { console.warn("chart", sel, e); } }
    });
  }

  var built = false, bound = false, ro = null;
  function render() {
    if (typeof d3 === "undefined") { setTimeout(render, 120); return; }
    var root = document.getElementById("analytics-root");
    if (!root) return;
    var m = buildModel();
    initSelection(m);

    if (!built) {
      root.innerHTML =
        kpiStrip(m) + zoomBar() +
        '<div class="an-grid">' +
          card("Tickets", "Lifecycle per ticket — queued → in-progress → review → merged. Click a bar for the ticket.", "an-gantt", "wide scroll") +
          card("Per-unit CPU", "Stacked CPU across the Executor and every unit. The machine ceiling caps the stack.", "an-cpu", "wide", legendSlot()) +
          card("Concurrency vs cap", "Active units against the cap. Shaded band is wasted headroom.", "an-conc", "") +
          card("Memory over run", "Aggregate memory against the host ceiling — the real limiter on running more units.", "an-mem", "") +
          card("Cost per ticket", "CPU-seconds burned per ticket. Toggle to rank by peak CPU or peak memory.", "an-cost", "scroll", costToggle()) +
          card("Burn-up", "Cumulative tickets merged against total scope.", "an-burn", "") +
          card("Complexity breakdown", "Ticket count by complexity tier with average wall-clock.", "an-cx", "") +
        '</div>';
      built = true;
      bindLegend(root);
      bindCostToggle(root);
      bindZoom(root);
    } else {
      // refresh legend chip states + kpis
      var lg = root.querySelector(".an-legend"); if (lg) lg.outerHTML = legend(m);
      var kp = root.querySelector(".an-kpis"); if (kp) kp.outerHTML = kpiStrip(m);
      bindLegend(root);
    }
    renderAll(root, m);
    updateZoomBar();

    if (!bound) {
      bound = true;
      var deb;
      window.addEventListener("resize", function () { clearTimeout(deb); deb = setTimeout(function () { if (isVisible()) renderAll(document.getElementById("analytics-root"), buildModel()); }, 160); });
      var mo = new MutationObserver(function () { if (isVisible()) render(); });
      mo.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    }
  }
  function isVisible() {
    var pnl = document.querySelector('.panel[data-panel="analytics"]');
    return pnl && pnl.classList.contains("is-active");
  }
  function card(title, sub, chartId, cls, extra) {
    return '<section class="section-card an-card ' + (cls || "") + '">' +
      '<div class="an-card-head"><div><h3 class="an-card-title">' + title + '</h3><p class="an-card-sub">' + sub + '</p></div>' +
      (extra && extra.act ? extra.act : "") + '</div>' +
      (extra && extra.pre ? extra.pre : "") +
      '<div class="an-chart" id="' + chartId + '"></div></section>';
  }
  function legendSlot() { return { pre: '<div id="an-legend-slot"></div>' }; }
  function costToggle() {
    return { act: '<div class="an-seg" id="an-cost-seg">' +
      '<button data-s="cpu" class="on">CPU·s</button><button data-s="peakcpu">Peak CPU</button><button data-s="mem">Peak mem</button></div>' };
  }
  function bindLegend(root) {
    // place legend into slot under CPU chart
    var m = buildModel();
    var slot = root.querySelector("#an-legend-slot");
    if (slot && !root.querySelector(".an-legend")) slot.innerHTML = legend(m);
    root.querySelectorAll(".an-chip").forEach(function (b) {
      b.onclick = function () {
        var id = b.dataset.tid;
        if (selected.has(id)) selected.delete(id); else selected.add(id);
        b.classList.toggle("on");
        renderAll(root, buildModel());
        refreshKpisAndDeps(root);
      };
    });
    root.querySelectorAll(".an-lg-btn").forEach(function (b) {
      b.onclick = function () {
        var mm = buildModel();
        if (b.dataset.lg === "all") mm.agents.forEach(function (a) { selected.add(a.id); });
        else selected.clear();
        root.querySelectorAll(".an-chip").forEach(function (c) { c.classList.toggle("on", selected.has(c.dataset.tid)); });
        renderAll(root, mm); refreshKpisAndDeps(root);
      };
    });
  }
  function refreshKpisAndDeps(root) { /* KPIs stay run-global; nothing to recompute */ }
  function bindCostToggle(root) {
    var seg = root.querySelector("#an-cost-seg");
    if (!seg) return;
    seg.querySelectorAll("button").forEach(function (b) {
      b.onclick = function () {
        seg.querySelectorAll("button").forEach(function (x) { x.classList.remove("on"); });
        b.classList.add("on");
        costSort = b.dataset.s === "cpu" ? "cpu" : b.dataset.s === "mem" ? "mem" : "peakcpu";
        chartCost(root.querySelector("#an-cost"), buildModel());
      };
    });
  }

  function zoomBar() {
    return '<div id="an-zoombar" class="an-zoombar" style="display:none">' +
      '<svg class="an-zoom-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="7"></circle><path d="m21 21-4.3-4.3M8 11h6"></path></svg>' +
      '<span>Zoomed to <b class="an-zoom-range"></b> — drag any time chart to zoom</span>' +
      '<button class="an-zoom-reset" type="button">Reset zoom</button></div>';
  }
  function bindZoom(root) {
    var b = root.querySelector(".an-zoom-reset");
    if (b) b.onclick = function () { timeDomain = [0, NOW]; rerenderTime(); };
  }
  function updateZoomBar() {
    var bar = document.getElementById("an-zoombar"); if (!bar) return;
    var full = timeDomain[0] <= 0.6 && timeDomain[1] >= NOW - 0.6;
    bar.style.display = full ? "none" : "flex";
    var lbl = bar.querySelector(".an-zoom-range"); if (lbl) lbl.textContent = fmtElapsed(timeDomain[0]) + " – " + fmtElapsed(timeDomain[1]);
  }
  function rerenderTime() {
    var root = document.getElementById("analytics-root"); if (!root) return;
    var m = buildModel();
    var fns = { "#an-cpu": chartCPU, "#an-conc": chartConc, "#an-mem": chartMem, "#an-burn": chartBurn, "#an-gantt": chartGantt };
    Object.keys(fns).forEach(function (sel) { var el = root.querySelector(sel); if (el) { try { fns[sel](el, m); } catch (e) { console.warn(sel, e); } } });
    updateZoomBar();
  }
  window.AiurAnalytics = { render: render };
})();
