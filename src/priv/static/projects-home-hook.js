(function (root) {
  "use strict";

  var TIMEOUT_MS = 3000;
  var POLL_MS = 10000;
  var CACHE_MS = 7 * 24 * 3600 * 1000;

  function age(ms) {
    var s = Math.max(0, Math.round(ms / 1000));
    if (s < 60) return s + "s";
    if (s < 3600) return Math.round(s / 60) + "m";
    if (s < 86400) return Math.round(s / 3600) + "h";
    return Math.round(s / 86400) + "d";
  }

  function nonNegInt(v) { return typeof v === "number" && isFinite(v) && v >= 0; }

  function validSummary(b) {
    return !!b && typeof b === "object" && typeof b.observed_at === "string" && nonNegInt(b.age_ms) &&
      !!b.capacity && nonNegInt(b.capacity.running) && nonNegInt(b.capacity.max) && Array.isArray(b.projects);
  }

  // A timeout, a throw, a CORS or TLS block all collapse to "unknown": no cause is named.
  function classifyResult(r) {
    if (r.timedOut || r.threw) return { connectivity: "unknown", reason: null };
    if (r.status === 401 || r.status === 403) return { connectivity: "error", reason: "signed out" };
    if (r.status >= 500) return { connectivity: "error", reason: "server " + r.status };
    if (r.status >= 200 && r.status < 300) {
      if (r.body && r.expectedGatewayId && r.body.gateway_id !== r.expectedGatewayId) return { connectivity: "error", reason: "gateway id mismatch" };
      if (!validSummary(r.body)) return { connectivity: "error", reason: "unreadable summary" };
      return { connectivity: "online", reason: null };
    }
    return { connectivity: "unknown", reason: null };
  }

  function workloadOf(summary) {
    return summary.capacity.running + " of " + summary.capacity.max + " agents";
  }

  // lastKnown is {observed_at_ms, summary} or null. Unknown is never rendered as zero or idle.
  function displayState(connectivity, reason, lastKnown, now, live) {
    var cached = lastKnown ? "last known: " + workloadOf(lastKnown.summary) + " " + age(now - lastKnown.observed_at_ms) + " ago" : "workload unknown";
    if (connectivity === "online") return { connectivityText: "online", workloadText: workloadOf(live), ageText: "seen " + age(live.age_ms) + " ago" };
    if (connectivity === "connecting") return { connectivityText: "connecting…", workloadText: "workload unknown", ageText: "" };
    if (connectivity === "error") return { connectivityText: "error: " + reason, workloadText: cached, ageText: "" };
    if (!lastKnown) return { connectivityText: "unknown · never seen on this device", workloadText: "workload unknown", ageText: "" };
    return { connectivityText: "unreachable · last seen " + age(now - lastKnown.observed_at_ms) + " ago", workloadText: cached, ageText: "" };
  }

  // Only online gateways are summed; a cached figure never counts.
  function totals(gateways) {
    var running = 0, max = 0, unknown = 0;
    gateways.forEach(function (g) {
      if (g.connectivity === "online") { running += g.summary.capacity.running; max += g.summary.capacity.max; } else unknown += 1;
    });
    var text = "Running " + running + " of " + max + (unknown ? "+ · " + unknown + (unknown === 1 ? " gateway" : " gateways") + " unknown" : "");
    return { running: running, capacity: max, unknownGateways: unknown, text: text };
  }

  function cacheKey(id) { return "aiur.projectsHome.v1." + id; }

  function readCache(storage, id, now) {
    try {
      var raw = storage.getItem(cacheKey(id));
      if (raw === null || raw === undefined) return null;
      var v = JSON.parse(raw);
      if (v && nonNegInt(v.observed_at_ms) && now - v.observed_at_ms <= CACHE_MS && validSummary(v.summary)) return v;
      storage.removeItem(cacheKey(id));
    } catch (e) {
      try { storage.removeItem(cacheKey(id)); } catch (e2) { /* no storage */ }
    }
    return null;
  }

  function writeCache(storage, id, now, summary) {
    try { storage.setItem(cacheKey(id), JSON.stringify({ observed_at_ms: now, summary: summary })); } catch (e) { /* no cache */ }
  }

  var model = { classifyResult: classifyResult, displayState: displayState, totals: totals, readCache: readCache, writeCache: writeCache };
  if (typeof module !== "undefined" && module.exports) module.exports = model;
  if (!root || !root.document) return;

  function el(tag, text, attrs) {
    var n = root.document.createElement(tag);
    if (text !== undefined) n.textContent = text;
    Object.keys(attrs || {}).forEach(function (k) { n.setAttribute(k, attrs[k]); });
    return n;
  }

  function storage() { try { return root.localStorage; } catch (e) { return { getItem: function () { return null; }, setItem: function () {}, removeItem: function () {} }; } }

  function fetchPeer(peer) {
    var ctl = new AbortController();
    var timer = setTimeout(function () { ctl.abort(); }, TIMEOUT_MS);
    var out = { timedOut: false, threw: false, expectedGatewayId: peer.gateway_id };
    return fetch(peer.url + "/api/v1/gateway/summary", { credentials: "include", signal: ctl.signal })
      .then(function (res) {
        out.status = res.status;
        return res.json().then(function (b) { out.body = b; }, function () { out.body = null; });
      })
      .catch(function (e) { if (ctl.signal.aborted) out.timedOut = true; else out.threw = true; })
      .then(function () { clearTimeout(timer); return out; });
  }

  root.AiurProjectsHomeHook = {
    mounted: function () {
      var self = this;
      this.peers = JSON.parse(this.el.dataset.peers || "[]");
      this.state = {};
      this.peers.forEach(function (p) { self.state[p.name] = { connectivity: "connecting", reason: null, summary: null }; });
      this.render();
      this.poll();
      this.timer = setInterval(function () { self.poll(); }, POLL_MS);
    },
    destroyed: function () { clearInterval(this.timer); },
    poll: function () {
      var self = this;
      this.peers.forEach(function (peer) {
        if (peer.off_tailnet) { self.state[peer.name] = { connectivity: "unknown", reason: null, summary: null, linkOnly: true }; self.render(); return; }
        fetchPeer(peer).then(function (r) {
          var c = classifyResult(r);
          var s = self.state[peer.name] = { connectivity: c.connectivity, reason: c.reason, summary: c.connectivity === "online" ? r.body : null };
          if (s.summary) writeCache(storage(), peer.gateway_id || peer.name, Date.now(), s.summary);
          self.render();
        });
      });
    },
    render: function () {
      var self = this, now = Date.now(), store = storage();
      var cards = this.el.querySelector("[data-cards]");
      var local = root.document.getElementById("projects-home-local");
      var all = [];
      if (local) {
        // An unreadable local count has no data attribute; it counts as unknown, never as zero.
        var lr = local.dataset.running, lm = local.dataset.max;
        all.push(lr !== undefined && lm !== undefined ? { connectivity: "online", summary: { capacity: { running: +lr, max: +lm } } } : { connectivity: "unknown", summary: null });
      }
      cards.textContent = "";
      this.peers.forEach(function (peer) {
        var s = self.state[peer.name];
        var cached = readCache(store, peer.gateway_id || peer.name, now);
        all.push({ connectivity: s.connectivity, summary: s.summary });
        var d = displayState(s.connectivity, s.reason, cached, now, s.summary);
        var card = el("div", undefined, { "class": "bo-state-card", "data-gateway-card": peer.name, "data-connectivity": s.connectivity });
        card.appendChild(el("h3", peer.label));
        card.appendChild(el("p", d.connectivityText + (d.ageText ? " · " + d.ageText : ""), { "data-conn-text": "" }));
        card.appendChild(el("p", d.workloadText));
        if (s.connectivity === "online") {
          s.summary.projects.forEach(function (p) {
            var row = el("p", String(p.repo) + " · running " + (p.running === null ? "unknown" : p.running) + " ", { "data-project-row": String(p.repo) });
            row.appendChild(el("a", "Build ›", { href: peer.url + "/build" }));
            card.appendChild(row);
          });
        }
        if (s.reason === "signed out") {
          card.appendChild(el("a", "Sign in", { href: peer.url + "/auth/google?return_to=" + encodeURIComponent(root.location.href) }));
        }
        card.appendChild(el("a", "Open ›", { href: peer.url + "/build" }));
        cards.appendChild(card);
      });
      this.el.querySelector("[data-totals]").textContent = totals(all).text;
    }
  };
})(typeof window !== "undefined" ? window : null);
