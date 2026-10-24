// Port of design build.js:366–379 and 1074–1090; figures cover the whole index.
import { S, ctx, fx, onReset } from './state.js';
import { $, esc } from './dom.js';
import { I } from './icons.js';
import { writeURL } from './url.js';
import { ensureFrom } from './history.js';

export const activeFeature = (D = ctx.D, state = S) =>
  state.feature && D && Object.hasOwn(D.features, state.feature) ? state.feature : null;

export function layoutExt(D, state) {
  const F = activeFeature(D, state), compact = !!(F && state.fmode === 'compact');
  if (!compact) return { compact: false };
  const inF = t => t.feature === F || t.also.includes(F), ghost = new Set();
  D.all.filter(inF).forEach(t => t.deps.forEach(d => { const x = D.byId[d]; if (x && !inF(x)) ghost.add(d); }));
  const entries = list => {
    const out = []; let g = null;
    list.forEach(t => {
      if (inF(t) || ghost.has(t.id)) { if (g) { out.push({ gap: g }); g = null; } out.push({ t, ghost: !inF(t) }); }
      else { if (!g) g = { n: 0, a: t.end || null, b: t.end || null }; g.n++; if (t.end) g.b = t.end; }
    });
    if (g) out.push({ gap: g });
    return out;
  };
  return { compact, entries };
}
let spanRun = 0;
onReset(() => { spanRun++; });
export function loadFeatureSpan(k) {
  const run = ++spanRun, f = k && activeFeature() === k ? ctx.D.features[k] : null;
  if (f?.oldest == null) return Promise.resolve();
  const life = ctx.life;
  return ensureFrom(f.oldest, () => run === spanRun && activeFeature() === k && ctx.life === life && !life.disposed);
}
const kv = (label, value, title) => '<div class="bd-kv"><small>' + label + '</small><b' + (title ? ' title="' + esc(title) + '"' : '') + '>' + value + '</b></div>';
function sparkline(s, hue) {
  const spark = s?.spark || [], max = Math.max(...spark), min = Math.min(...spark), n = spark.length;
  const pts = spark.map((v, i) => (n === 1 ? 0 : i / (n - 1) * 74 + 1).toFixed(1) + ',' + (20 - (max === min ? 10 : (v - min) / (max - min) * 18)).toFixed(1)).join(' ');
  return '<svg class="sp" viewBox="0 0 76 22">' + (n ? '<polyline points="' + pts + '" fill="none" stroke="oklch(.68 .14 ' + hue + ')" stroke-width="1.6" stroke-linejoin="round"/>' : '') + '</svg>';
}
export function figuresHTML(s, hue) {
  const unavailable = 'Feature figures unavailable', reasons = s?.reasons?.join(', ') || '';
  const doneTitle = !s ? unavailable : s.done == null ? 'at least ' + s.done_min + ' done · unknown: ' + reasons : null;
  const weightedTitle = !s ? unavailable : s.pct != null ? null : s.pct_min != null ? 'at least ' + s.pct_min + '% weighted · unknown: ' + reasons : s.reasons.includes('no_weight') ? 'No weighted tickets' : 'unknown: ' + reasons;
  const scopeTitle = !s ? unavailable : !s.baseline ? 'No baseline set' : null;
  return kv('Done', s ? (s.done ?? '—') + '/' + s.total : '—', doneTitle) +
    kv('Weighted', s?.pct == null ? '—' : s.pct + '%', weightedTitle) +
    kv('Scope · original → now', (!s ? '—' : (s.baseline ? s.orig : '—') + ' → ' + s.total + (s.baseline && s.added > 0 ? ' <em>+' + s.added + '</em>' : '')) + sparkline(s, hue), scopeTitle);
}
export function renderFeatures() {
  const host = $('#bd-fh', ctx.root); if (!host) return;
  wireFeatures(host);
  const focusedMode = host.contains(document.activeElement) ? document.activeElement.dataset.m : null;
  const F = activeFeature(); if (!F) { host.innerHTML = ''; return; }
  const D = ctx.D, f = D.features[F], hue = +f.hue, s = f.stats;
  host.innerHTML = '<div class="bd-fh" style="--fh:' + hue + '">' +
    '<div class="bd-fh-name"><i></i>' + esc(f.label) + '</div>' + figuresHTML(s, hue) +
    '<div class="bd-fh-controls" style="display:flex;align-items:center;gap:.5rem"><div class="bd-seg">' +
    ['focus', 'compact'].map(m => '<button type="button" data-m="' + m + '" class="' + (S.fmode === m ? 'on' : '') + '">' + I[m] + (m === 'focus' ? 'Focus' : 'Compact') + '</button>').join('') +
    '</div><button class="bd-x" type="button" id="bd-fx" aria-label="Clear feature">' + I.x + '</button></div>' +
    '<div class="bd-fh-ep">' + f.epics.filter(k => Object.hasOwn(D.epics, k)).map(k => '<span class="bd-chip" style="color:oklch(.7 .13 ' + hue + ')">' + I.lock + esc(D.epics[k].label) + '</span>').join('') +
    (s?.also > 0 ? '<span class="bd-chip">+' + s.also + ' also affect</span>' : '') + '</div></div>';
  if (focusedMode) host.querySelector('[data-m="' + focusedMode + '"]')?.focus();
}
let wired = new WeakSet();
onReset(() => { wired = new WeakSet(); });
function wireFeatures(host) {
  if (wired.has(host)) return;
  wired.add(host);
  ctx.life.on(host, 'click', e => {
    const b = e.target.closest('[data-m], #bd-fx'); if (!b || !host.contains(b)) return;
    if (b.id === 'bd-fx') { fx.setFeature(null); $('[data-g="feature"]', ctx.root)?.focus(); return; }
    S.fmode = b.dataset.m; writeURL(); renderFeatures(); fx.relayout();
  });
}
Object.assign(fx, { renderFeatures, activeFeature });
