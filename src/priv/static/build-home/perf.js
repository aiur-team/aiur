// Opt-in User Timing for the build home (MP-E8-C12-T06). Off unless the tab sets
// sessionStorage["bd-perf"] = "1": measure entries have no buffer limit, so an always-on
// measure would grow memory in a tab left open for days. Off, timed() returns fn itself.
let on = false;
try { on = sessionStorage.getItem('bd-perf') === '1'; } catch { on = false; }
export const perfOn = () => on;
// A failing measure turns timing off; it never breaks the wrapped call.
const mark = (name, start) => { try { performance.measure('bd:' + name, { start }); } catch { on = false; } };
// Synchronous functions only: an async one would be measured up to its first await.
export function timed(name, fn) {
  if (!on) return fn;
  return function (...args) { const start = performance.now(); try { return fn.apply(this, args); } finally { mark(name, start); } };
}
export function markFirstBoard() { if (on && !performance.getEntriesByName('bd:first-board').length) mark('first-board', 0); }
