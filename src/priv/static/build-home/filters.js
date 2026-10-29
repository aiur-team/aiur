import { loadFeatureSpan } from './features.js';
// Port of design build.js:1091–1127; real-data differences follow C10-T02.
import { S, ctx, fx, onReset, FKEYS } from './state.js';
import { $, $$, esc } from './dom.js';
import { writeURL } from './url.js';
import { I } from './icons.js';
import { AST } from './now-state.js';
import { modelInfo } from './agents.js';
import { LOGOS } from './logos.js';
import { NP, colKey, tstate } from './match.js';
import { syncAst } from './band.js';
export { syncAst } from './band.js';

export const rowOk = (state, t) => (!state.f.epic.length || state.f.epic.includes(colKey(t))) && (tstate(t) !== NP || state.f.tstate.includes(NP));
export const layoutKey = state => state.f.epic.join(',') + (state.f.tstate.includes(NP) ? '|np' : '');
let lastKey = '';
export const setLastKey = key => { lastKey = key; };
onReset(() => { lastKey = ''; });
const selected = k => k === 'feature' ? (S.feature ? [S.feature] : []) : S.f[k];
const ticketOptions = [['merged', 'Merged', 'merged'], ['failed', 'Failed', 'failed'], ['in progress', 'In progress', 'active'], ['queued', 'Queued', 'queued'], ['held', 'Held', 'held'], ['blocked', 'Blocked', 'blocked'], ['open', 'Not queued', 'open']];
function featureOption(f) {
  const s = f.stats, known = Number.isInteger(s?.pct) && s.pct >= 0 && s.pct <= 100;
  const title = known ? null : (s?.pct_min == null ? 'unknown' : 'at least ' + s.pct_min + '% weighted · unknown: ' + (s.reasons || []).join(', '));
  return [f.key, f.label + '  ' + (known ? s.pct + '%' : '—'), null, f.hue, null, null, title];
}
// shortcut: row-only diffs refresh open options on the next render; revisit for live option updates.
export function FOPTS() {
  const D = ctx.D ?? { all: [], hist: [], features: {}, epics: {}, order: [], counts: {} };
  const models = [...new Set([...D.all.map(t => t.agent?.model), ...S.f.model])].filter(k => typeof k === 'string' && k && !Object.hasOwn(LOGOS, k)).sort();
  const features = Object.values(D.features).filter(f => f.stats?.total > 0 || !f.stats || f.key === S.feature)
    .sort((a, b) => (a.from ?? 0) - (b.from ?? 0) || a.key.localeCompare(b.key));
  const recent = features.filter(f => f.stats?.total > 0 || !f.stats).slice(-6);
  const current = Object.hasOwn(D.features, S.feature) ? D.features[S.feature] : null;
  if (current && !recent.includes(current)) recent.push(current);
  const epics = D.order.filter(k => (D.counts == null || D.counts[k] > 0) && Object.hasOwn(D.epics, k));
  for (const k of S.f.epic) if (!epics.includes(k)) epics.push(k);
  const tickets = [...ticketOptions];
  if (D.hist.some(t => t.status === 'not_planned') || S.f.tstate.includes(NP)) tickets.push([NP, 'Not planned', 'np']);
  return {
    model: { label: 'Model', opts: Object.keys(LOGOS).map(k => [k, modelInfo(k).name, LOGOS[k].src]).concat(models.map(k => [k, modelInfo(k).name, null, null, null, modelInfo(k).mono])) },
    feature: { label: 'Feature', opts: recent.map(featureOption).concat(S.feature && !current ? [[S.feature, S.feature]] : []) },
    epic: { label: 'Epic', opts: epics.map(k => [k, D.epics[k]?.label ?? k, null, D.epics[k]?.unsorted ? null : D.epics[k]?.hue]) },
    tstate: { label: 'Ticket', opts: tickets.map(o => [o[0], o[1], null, null, o[2]]) },
    astate: { label: 'Agent', opts: Object.keys(AST).map(v => [v, AST[v].label, null, null, AST[v].cls]).concat([['none', 'No agent', null, null, 'open']]) },
  };
}
function optionHTML(o, k) {
  return '<button class="bd-opt' + (o[4] ? ' lst st-' + o[4] : '') + (selected(k).includes(o[0]) ? ' on' : '') + '" type="button" data-o="' + esc(o[0]) + '" aria-pressed="' + selected(k).includes(o[0]) + '"' + (o[6] ? ' title="' + esc(o[6]) + '"' : '') + '>' + (o[4] ? '<u></u>' : '') + (o[2] ? '<img src="' + esc(o[2]) + '" alt="">' : Number.isFinite(o[3]) ? '<i style="background:oklch(.66 .14 ' + o[3] + ')"></i>' : o[5] ? '<span class="ax-mono" aria-hidden="true">' + esc(o[5]) + '</span>' : '') + esc(o[1]) + '</button>';
}
export function renderFilters() {
  const host = $('#bd-filters', ctx.root); if (!host) return;
  const O = FOPTS(), active = host.contains(document.activeElement) ? document.activeElement : null;
  const attr = active?.hasAttribute('data-o') ? 'data-o' : 'data-g', value = active?.getAttribute(attr), group = active?.dataset.g || S.pop;
  let html = I.filter;
  FKEYS.forEach(k => {
    const n = k === 'feature' ? (fx.activeFeature() ? 1 : 0) : selected(k).length;
    html += '<button class="bd-fg' + (n ? ' has' : '') + (S.pop === k ? ' open' : '') + '" type="button" data-g="' + k + '" aria-expanded="' + (S.pop === k) + '"' + (S.pop === k ? ' aria-controls="bd-pop"' : '') + '>' + O[k].label + (n ? ' <b>' + n + '</b>' : '') + I.chev + '</button>';
  });
  if (FKEYS.some(k => selected(k).length)) html += '<button class="bd-fclear" type="button" id="bd-fclr">Clear</button>';
  if (S.pop) html += '<div class="bd-pop" id="bd-pop" role="group" aria-label="' + O[S.pop].label + '">' + O[S.pop].opts.map(o => optionHTML(o, S.pop)).join('') + '</div>';
  host.innerHTML = html;
  $$('[data-g]', host).forEach(b => b.onclick = e => { e.stopPropagation(); S.pop = S.pop === b.dataset.g ? null : b.dataset.g; renderFilters(); });
  const clr = $('#bd-fclr', host);
  if (clr) clr.onclick = () => { FKEYS.forEach(k => S.f[k] = []); S.pop = null; if (S.feature) setFeature(null); else filtersChanged(); };
  const pop = $('#bd-pop', host);
  if (pop) {
    pop.style.left = $('[data-g="' + S.pop + '"]', host).offsetLeft + 'px';
    $$('[data-o]', pop).forEach(b => b.onclick = e => {
      e.stopPropagation(); const k = S.pop, v = b.dataset.o;
      if (k === 'feature') { S.pop = null; setFeature(S.feature === v ? null : v); $('[data-g="feature"]', host)?.focus(); return; }
      S.f[k] = S.f[k].includes(v) ? S.f[k].filter(x => x !== v) : S.f[k].concat(v); filtersChanged();
    });
  }
  if (value != null) ($('[' + attr + '="' + CSS.escape(value) + '"]', host) || $('[data-g="' + group + '"]', host))?.focus({ preventScroll: true });
  syncAst();
}
function changedLayout() {
  const key = layoutKey(S);
  if (ctx.D && key.split('|')[0] !== lastKey.split('|')[0]) ctx.D._fwd = null;
  return key !== lastKey;
}
export function filtersChanged() {
  writeURL(); renderFilters(); syncAst();
  const changed = changedLayout();
  if (S.loading || !ctx.D) return;
  if (S.view === 'list') fx.renderList(); else if (changed) fx.relayout(); else fx.decorateAll();
}
export function setFeature(k) {
  const wasCompact = S.feature && S.fmode === 'compact';
  S.feature = k; if (!k) S.fmode = 'focus';
  writeURL(); fx.renderFeatures(); renderFilters();
  if (S.loading || !ctx.D) return;
  const changed = changedLayout();
  if (S.view === 'list') fx.renderList();
  else if (changed || wasCompact || (k && S.fmode === 'compact')) fx.relayout(); else { fx.decorateAll(); fx.applyCols(fx.visibleCols()); }
  if (k) loadFeatureSpan(k);
}
Object.assign(fx, { renderFilters, filtersChanged, syncAst, setFeature });
