/**
 * The "Build order" view: the published `build-order.v1` document rendered by
 * the `aiur-build-order` package, so the dashboard owns no second review or
 * graph renderer.
 *
 * The page reads `GET /api/v1/build-order` — the document the daemon publishes
 * from the projection it already read — once per mount. It needs no tracker
 * credential and asks the daemon for nothing else per render. A focused
 * build-order root (`?feature=bo-<root>`) selects that root's document; every
 * other state reads the whole catalog. The element renders the stale and
 * unknown banners from `sources.*.status` itself, so the page never invents a
 * status the document did not publish.
 */
import { S, ctx, fx, onReset } from './state.js';
import { $ } from './dom.js';
import { buildOrderViewport } from './render.js';

const SOURCE = '/api/v1/build-order';
const MODULE_URL = '/aiur-build-order/index.js';
const ROOT = /^bo-(\d{1,19})$/;
const UNAVAILABLE = 'Build order review unavailable';

let importing = null;
let mounting = null;
let element = null;
let mountedSource = null;
let mountedEpoch = null;
let document_ = null;
let failure = null;
const listeners = [];

function clearMount() {
  element = null; mountedSource = null; mountedEpoch = null; document_ = null; failure = null; mounting = null;
  listeners.splice(0).forEach(off => off());
}

onReset(clearMount);

/** The document URL this view reads for one URL state. */
export function documentSource(state = S) {
  const match = ROOT.exec(state.feature ?? '');
  return match ? `${SOURCE}?root=${match[1]}` : SOURCE;
}

/** What the mounted element last reported, for the status line and for specs. */
export function buildOrderStatus() {
  return {
    source: mountedSource,
    status: document_?.status ?? null,
    contract: document_?.contract ?? null,
    sources: document_?.sources ?? null,
    error: failure,
  };
}

// The host is reused only while it still contains the element this module
// mounted: a repaint that rebuilt the viewport must not leave a detached
// element behind.
function container() {
  const vp = $('#bd-vp', ctx.root);
  if (!vp) return null;
  const host = $('#bd-bo', ctx.root);
  if (host && vp.contains(host) && (!element || host.contains(element))) return host;
  clearMount();
  return null;
}

function load() {
  if (importing) return importing;
  importing = import(MODULE_URL).catch(error => { importing = null; throw error; });
  return importing;
}

function writeStatus(host) {
  if (!host) return;
  const status = buildOrderStatus();
  host.dataset.buildOrderSource = status.source ?? '';
  if (status.error) {
    host.dataset.buildOrderStatus = 'error';
    host.dataset.buildOrderReason = status.error;
    return;
  }
  host.dataset.buildOrderStatus = status.status ?? 'loading';
  host.dataset.buildOrderContract = status.contract ?? '';
  const stale = Object.values(status.sources ?? {}).filter(source => source?.status && source.status !== 'known');
  host.dataset.buildOrderSources = stale.map(source => source.name).join(',');
}

function unavailable(host, text) {
  const note = document.createElement('p');
  note.className = 'bd-bo-error';
  note.setAttribute('role', 'status');
  note.textContent = text;
  host.innerHTML = '';
  host.appendChild(note);
}

function mount(host, next) {
  clearMount();
  mounting = next;
  host.innerHTML = '';
  mountedSource = next;
  mountedEpoch = ctx.proto.epoch;
  writeStatus(host);
  load().then(() => {
    if (!host.isConnected || mountedSource !== next || ctx.life?.disposed) return;
    const node = document.createElement('aiur-build-order');
    node.setAttribute('view', 'both');
    node.setAttribute('src', next);
    listeners.push(ctx.life.on(node, 'aiur-build-order:load', event => {
      document_ = event.detail?.document ?? null;
      failure = null;
      writeStatus(host);
    }));
    listeners.push(ctx.life.on(node, 'aiur-build-order:error', event => {
      document_ = null;
      failure = event.detail?.error?.code ?? 'error';
      writeStatus(host);
    }));
    host.appendChild(node);
    element = node;
    mounting = null;
    writeStatus(host);
  }, () => {
    if (!host.isConnected) return;
    failure = 'package';
    writeStatus(host);
    unavailable(host, UNAVAILABLE + ' · the aiur-build-order package did not load');
  });
}

/** Render or refresh the view's content. Called by the board's relayout. */
export function mountBuildOrder() {
  let host = container();
  if (!host) {
    buildOrderViewport();
    host = container();
  }
  if (!host) return;
  const next = documentSource();
  if (!element && mounting === next) return;
  if (!element || mountedSource !== next) return mount(host, next);
  if (mountedEpoch !== null && mountedEpoch !== ctx.proto.epoch) {
    mountedEpoch = ctx.proto.epoch;
    if (element.isConnected) element.load?.();
  }
  writeStatus(host);
}

Object.assign(fx, { mountBuildOrder });
