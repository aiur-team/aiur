(function (root) {
  "use strict";
  if (!root || !root.document) return;

  var TIMEOUT_MS = 3000;
  var POLL_MS = 10000;
  var CACHE_KEY = "aiur.projectsHome.v1."; // the cache projects-home-hook.js writes, shared on purpose

  function el(tag, text, attrs) {
    var n = root.document.createElement(tag);
    if (text !== undefined && text !== null) n.textContent = text;
    Object.keys(attrs || {}).forEach(function (k) { n.setAttribute(k, attrs[k]); });
    return n;
  }

  function store() { try { return root.localStorage; } catch (e) { return null; } }

  function readCache(id) {
    try {
      var v = JSON.parse(store().getItem(CACHE_KEY + id));
      return v && typeof v.observed_at_ms === "number" && v.summary ? v : null;
    } catch (e) { return null; }
  }

  function writeCache(id, summary) {
    try { store().setItem(CACHE_KEY + id, JSON.stringify({ observed_at_ms: Date.now(), summary: summary })); } catch (e) { /* no cache */ }
  }

  // Resolves {status, body} or {noAnswer: true, timedOut}; never rejects. A network, TLS or CORS failure cannot be told apart.
  function request(url, init) {
    var ctl = new AbortController();
    var timer = setTimeout(function () { ctl.abort(); }, TIMEOUT_MS);
    init.signal = ctl.signal;
    init.credentials = "include";
    return fetch(url, init)
      .then(function (res) { return res.json().then(function (b) { return { status: res.status, body: b }; }, function () { return { status: res.status, body: null }; }); })
      .catch(function () { return { noAnswer: true, timedOut: ctl.signal.aborted }; })
      .then(function (r) { clearTimeout(timer); return r; });
  }

  function post(base, path) {
    return request(base + path, {
      method: "POST",
      headers: { "content-type": "application/json", "x-aiur-request": "1" },
      body: JSON.stringify({ request_id: root.crypto && root.crypto.randomUUID ? root.crypto.randomUUID() : String(Date.now()) })
    });
  }

  function asResult(r) {
    return r.noAnswer ? { noAnswer: true } : { status: r.status, globallyPaused: r.body ? r.body.globally_paused : undefined };
  }

  root.AiurGatewayViewHook = {
    mounted: function () {
      var self = this;
      this.peers = JSON.parse(this.el.dataset.peers || "[]");
      this.localName = this.el.dataset.localName || "local";
      this.selected = this.el.dataset.selected || "";
      this.state = {};
      this.peers.forEach(function (p) { self.state[p.name] = { pending: true }; });
      this.onClick = function (e) {
        var t = e.target.closest && e.target.closest("[data-action]");
        if (!t || !root.document.getElementById("gateway-view")) return;
        if (t.dataset.action === "pause-all") self.pauseAll();
        if (t.dataset.action === "pause-gateway") self.pauseOne(t.dataset.gateway);
      };
      root.document.addEventListener("click", this.onClick);
      this.render();
      this.poll();
      this.timer = setInterval(function () { self.poll(); }, POLL_MS);
    },
    destroyed: function () { clearInterval(this.timer); root.document.removeEventListener("click", this.onClick); },
    visible: function () { var s = this.selected; return this.peers.filter(function (p) { return !s || p.name === s; }); },
    poll: function () {
      var self = this;
      this.visible().forEach(function (peer) {
        if (peer.off_tailnet) { self.state[peer.name] = { linkOnly: true }; self.render(); return; }
        request(peer.url + "/api/v1/gateway/summary", {}).then(function (r) {
          var ok = !r.noAnswer && r.status >= 200 && r.status < 300 && r.body && r.body.capacity;
          self.state[peer.name] = { r: r, summary: ok ? r.body : null };
          if (ok) writeCache(peer.gateway_id || peer.name, r.body);
          self.render();
        });
      });
    },
    render: function () {
      var self = this, S = root.AiurGatewayState, box = this.el.querySelector("[data-cards]");
      box.textContent = "";
      this.visible().forEach(function (peer) {
        var st = self.state[peer.name] || { pending: true }, r = st.r || {};
        var c = S.connectivity({
          pending: st.pending, timedOut: r.timedOut, threw: r.noAnswer && !r.timedOut, status: r.status, summary: st.summary,
          idMatches: st.summary && peer.gateway_id ? st.summary.gateway_id === peer.gateway_id : true,
          offlineFlag: !!peer.offline, cached: readCache(peer.gateway_id || peer.name), now: Date.now()
        });
        var card = el("div", undefined, { "class": "bo-state-card", "data-gateway-card": peer.name, "data-connectivity": c.state });
        card.appendChild(el("h3", peer.label));
        if (st.linkOnly) {
          card.appendChild(el("p", "off tailnet: open its own dashboard", { "data-field": "connectivity" }));
        } else {
          card.appendChild(el("p", c.text, { "data-field": "connectivity" }));
          card.appendChild(el("p", c.workload || "workload unknown", { "data-field": "workload" }));
        }
        if (c.state === "online") {
          card.appendChild(el("p", st.summary.capacity.running + " of " + st.summary.capacity.max + " agents", { "data-field": "capacity" }));
          st.summary.projects.forEach(function (p) { card.appendChild(el("p", String(p.repo) + " · running " + (p.running === null ? "unknown" : p.running), { "data-project-row": String(p.repo) })); });
        }
        if (c.reason === "signed out") card.appendChild(el("a", "Sign in", { href: peer.url + "/auth/google?return_to=" + encodeURIComponent(root.location.href) }));
        if (!peer.off_tailnet) card.appendChild(el("button", "Pause " + peer.label, { type: "button", "data-action": "pause-gateway", "data-gateway": peer.name }));
        card.appendChild(el("span", "", { "data-pause-result": peer.name, role: "status" }));
        card.appendChild(el("a", "Open ›", { href: peer.url + "/build" }));
        box.appendChild(card);
      });
    },
    gateways: function () {
      var list = [{ name: this.localName, label: this.el.dataset.localLabel || "This gateway", url: "", local: true }];
      return list.concat(this.peers.map(function (p) { return { name: p.name, label: p.label, url: p.off_tailnet ? "" : p.url }; }));
    },
    pauseOne: function (name) {
      var g = this.gateways().filter(function (x) { return x.name === name; })[0];
      var out = root.document.querySelector('[data-pause-result="' + name + '"]');
      if (!g || !out) return;
      out.textContent = "pausing…";
      post(g.url, "/api/v1/gateway/pause").then(function (r) {
        // Reuse the report wording; one gateway never has shared-intent cover.
        var rep = root.AiurGatewayState.deliveryReport({ intentWritten: false, gateways: [g], results: (function () { var o = {}; o[g.name] = asResult(r); return o; })() });
        out.textContent = rep.lines[0].text;
      });
    },
    pauseAll: function () {
      var self = this, gws = this.gateways();
      if (root.confirm && !root.confirm("Pause all " + gws.length + " gateways?")) return;
      var report = root.document.getElementById("gateway-report");
      report.textContent = "Pausing…";
      // Intent first: if a direct call fails afterwards, the gateway still applies the pause when it reconnects.
      post("", "/api/v1/fleet/pause").then(function (fleet) {
        var intentWritten = !fleet.noAnswer && fleet.status === 200 && !!fleet.body && fleet.body.intent_written === true;
        return Promise.allSettled(gws.filter(function (g) { return g.url || g.local; }).map(function (g) {
          return post(g.url, "/api/v1/gateway/pause").then(function (r) { return [g.name, asResult(r)]; });
        })).then(function (settled) {
          var results = {};
          settled.forEach(function (s) { if (s.status === "fulfilled") results[s.value[0]] = s.value[1]; });
          var rep = root.AiurGatewayState.deliveryReport({ intentWritten: intentWritten, gateways: gws, results: results });
          report.textContent = "";
          report.appendChild(el("h3", rep.header));
          rep.lines.forEach(function (l) {
            var p = el("p", l.label + "  " + l.text, { "data-report-line": l.name });
            report.appendChild(p);
          });
        });
      });
    }
  };
})(typeof window !== "undefined" ? window : null);
