(function (root) {
  "use strict";

  function age(ms) {
    var s = Math.max(0, Math.round(ms / 1000));
    if (s < 60) return s + "s";
    if (s < 3600) return Math.round(s / 60) + "m";
    if (s < 86400) return Math.round(s / 3600) + "h";
    return Math.round(s / 86400) + "d";
  }

  // Connectivity (reachability) and workload (what the gateway is doing) are separate fields.
  // No answer is never `idle` and never `online`; the workload is the gateway's own `workload`, not recomputed here.
  // cached is {observed_at_ms, summary} or null.
  function connectivity(r) {
    var cached = r.cached || null, now = r.now;
    var ago = cached ? age(now - cached.observed_at_ms) : null;
    var last = cached ? "last known " + (cached.summary.workload || "unknown") + " (" + ago + " ago)" : null;
    if (r.pending) return { state: "connecting", text: "connecting…", workload: null, reason: null };
    if (r.timedOut || r.threw) {
      if (r.offlineFlag) return { state: "offline", text: "offline" + (ago ? " · last seen " + ago + " ago" : ""), workload: last, reason: null };
      if (!cached) return { state: "unknown", text: "unknown · never seen on this device", workload: null, reason: null };
      return { state: "unknown", text: "unreachable · last seen " + ago + " ago", workload: last, reason: null };
    }
    var reason = null;
    if (r.status === 401 || r.status === 403) reason = "signed out";
    else if (r.status >= 500) reason = "server " + r.status;
    else if (r.status >= 200 && r.status < 300) reason = r.idMatches === false ? "gateway id mismatch" : !r.summary ? "unreadable summary" : null;
    else reason = "status " + r.status;
    if (reason) return { state: "error", text: "error: " + reason, workload: last, reason: reason };
    return { state: "online", text: "online", workload: r.summary.workload || null, reason: null };
  }

  // results[name] is {status, globallyPaused} or {noAnswer: true}. A gateway with no answer is never "paused" and never "offline".
  function deliveryReport(r) {
    var lines = r.gateways.map(function (g) {
      var res = (r.results || {})[g.name] || { noAnswer: true };
      var text;
      if (!g.url && !g.local) text = "not paused: off tailnet, pause it from its own dashboard ↗";
      else if (res.noAnswer) text = r.intentWritten ? "will pause on reconnect   (unreachable; fleet pause is in shared intent)" : "not paused: unreachable and no shared store";
      else if (res.status === 401 || res.status === 403) text = "not paused: signed out";
      else if (res.status >= 200 && res.status < 300) text = res.globallyPaused === true ? "paused ✓" : "error: pause not applied";
      else text = "error: " + res.status;
      return { name: g.name, label: g.label || g.name, text: text, signIn: !!res.status && (res.status === 401 || res.status === 403) };
    });
    return { header: "Pause all — " + lines.length + (lines.length === 1 ? " gateway" : " gateways"), lines: lines };
  }

  var model = { connectivity: connectivity, deliveryReport: deliveryReport, age: age };
  if (typeof module !== "undefined" && module.exports) module.exports = model;
  if (root) root.AiurGatewayState = model;
})(typeof window !== "undefined" ? window : null);
