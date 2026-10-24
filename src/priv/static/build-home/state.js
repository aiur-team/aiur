import { fromServer } from './url.js';

export const SPANS = [1, 2, 3, 5, 7, 10, 14, 21, 30];
export const FKEYS = ['epic', 'feature', 'model', 'tstate', 'astate'];
export const LH = 46, SEC = 36;
export const S = {}, ctx = {};
const resets = [];
export const onReset = fn => resets.push(fn);
export function resetState(urlState = {}) {
  for (const key of Object.keys(S)) delete S[key];
  Object.assign(S, {
    view: 'graph', span: 1, feature: null, fmode: 'focus',
    f: { type: [], model: [], feature: [], epic: [], tstate: [], astate: [] },
    pop: null, loading: true, ready: false, flow: false, K: 2,
    density: 'card', trees: false, liveMin: false, ticket: null,
  });
  fromServer(urlState);
  for (const key of Object.keys(ctx)) delete ctx[key];
  Object.assign(ctx, {
    root: null, vp: null, content: null, lanesEl: null, guidesEl: null,
    svg: null, bandEl: null, secs: {}, R: new Map(), RL: new Map(),
    laneEls: new Map(), guideEls: new Map(), cols: [], colMap: {}, bandMap: {},
    a11y: { focusId: null }, lockId: null, hoverId: null, inited: false, D: null, L: null, snap: null,
    proto: { epoch: null, generation: null, inFlight: false }, resyncSeq: 0,
    socket: 'up', offline: false, urlPending: false, life: null, push: null, reload: null,
  });
  resets.forEach(fn => fn());
}
export const rmOn = () => window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
export const gutW = () => ctx.root.clientWidth < 640 ? 46 : 84;
export const isVisible = () => ctx.root && ctx.root.offsetParent !== null;

export function renderChrome() {
  fx.renderUsage(); fx.renderOffline(); fx.renderFeatures(); fx.renderFilters(); fx.renderTools();
}
function defaultDataChanged(msg) {
  if (Object.keys(msg.set ?? {}).length) renderChrome(); else fx.renderOffline();
  fx.relayout(); fx.update();
}
function defaultUnavailable(reason) {
  const loading = ctx.root?.querySelector('.bd-loading');
  if (!loading) return;
  const words = { not_wired: 'no data source', timeout: 'timed out', crashed: 'source crashed',
    version: 'page out of date, reload', invalid: 'invalid data' };
  loading.textContent = 'Build timeline unavailable · ' + (Object.hasOwn(words, reason) ? words[reason] : `unknown cause (${String(reason).slice(0, 80)})`);
}
export const fx = {
  viewport() {}, relayout() {}, update() {}, jumpNow() {}, liveGuard() {}, markScrolling() {},
  unlock() {}, closeTree() {}, chainOf: () => new Set(), renderFilters() {},
  renderUsage() {}, renderOffline() {}, renderFeatures() {}, renderTools() {},
  spanToolsHTML: () => '', wireSpanTools() {}, renderStatus() {},
  daemonView: () => ({ dotOff: true, dotText: 'Daemon status unknown' }),
  renderLoading() {}, renderUnavailable: defaultUnavailable, dataChanged: defaultDataChanged,
  drawEdgesSoon() {}, tickCardAges() {}, openFromURL() {}, flushLive() {}, renderHeads() {},
  makeCard: it => { const el = document.createElement('div'); el.className = 'bd-card'; el.dataset.id = it.t.id; el.tabIndex = -1; el._it = it; return el; },
  visibleCols: () => [], applyCols() {}, scheduleCols() {},
  initModal() {}, closeModal() {}, syncTicket() {}, modalSync() {}, renderDocBody() {}, renderConversation() {},
  drawEdges() {}, renderBand() {}, renderList() {}, openModal() {}, onHover() {}, setHover() {},
  lockTree() {}, fitTree() {}, openTree() {},
  appendEntries() {}, appendItem() {}, claimLocalOp: () => null, renderComposer() {}, composerState() {}, sendStatus() {}, scheduleMap() {}, wireLive() {}, onConversation() {}, reconnectConversation() {},
  renderCommand() {}, placeCommand() {},
};
