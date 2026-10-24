import { S, ctx, fx, resetState, renderChrome } from './state.js';
import { createLife } from './life.js';
import { shell } from './shell.js';
import { decide } from './protocol.js';
import { acceptSnapshot, applyDiff } from './store.js';
import { H } from './history.js';
import { fromServer, flushURL } from './url.js';
import { markFirstBoard } from './perf.js';
import './clock.js';
import './render.js';
import './columns.js';
import './cards.js';
import { seedDaemon } from './offline.js';
import './tools.js';
import './usage.js';

import './span.js';
import './edges.js';
import './trees.js';
import './band.js';
import './states.js';
import './list.js';
import { controlMessage } from './modal/frame.js';
import './modal/conversation.js';
import { applyDoc, applyQueueAdd, reconnectDoc } from './modal/doc.js';
import './modal/composer.js';
import './modal/command.js';

export function writeOwnData() {
  if (ctx.bdTrees != null) ctx.root.dataset.bdTrees = ctx.bdTrees;
  if (ctx.bdStates != null) ctx.root.dataset.bdStates = ctx.bdStates;
  Object.assign(ctx.root.dataset, { buildHomeHook: 'mounted', bdMounted: '', bdPaging: H.state, buildSocket: ctx.socket });
  if (ctx.proto.epoch !== null) {
    ctx.root.dataset.buildEpoch = ctx.proto.epoch;
    ctx.root.dataset.buildGeneration = ctx.proto.generation;
  }
}
function showServerState(ds) {
  if (ds.buildState === 'unavailable' && !ctx.snap) fx.renderUnavailable(ds.buildReason);
}
function firstPaint() {
  ctx.inited = true; S.loading = false;
  renderChrome(); fx.viewport(); fx.relayout(); markFirstBoard(); fx.jumpNow(true); S.ready = true;
  ctx.life.frame('ticket', () => fx.openFromURL());
}
function repaint() { renderChrome(); fx.relayout(); fx.update(); }
function reloadOnce() {
  try {
    if (!sessionStorage.getItem('aiur-build-reloaded')) {
      sessionStorage.setItem('aiur-build-reloaded', '1'); ctx.reload(); return;
    }
  } catch { /* Storage unavailable: show the version error instead of looping. */ }
  fx.renderUnavailable('version');
}
export function receive(msg) {
  if (msg.kind === 'error') { if (!ctx.snap) fx.renderUnavailable(msg.reason); return; }
  switch (decide({ ...ctx.proto, resyncing: ctx.proto.inFlight }, msg)) {
    case 'reload': reloadOnce(); break;
    case 'resync': resync(); break;
    case 'apply': {
      if (msg.kind !== 'snapshot' && msg.kind !== 'diff') return;
      const first = !ctx.snap;
      const result = msg.kind === 'snapshot' ? acceptSnapshot(msg) : applyDiff(msg);
      if (result.error) {
        if (msg.kind === 'diff') resync(); else fx.renderUnavailable('invalid');
        return;
      }
      fx.tickCardAges();
      if (msg.kind === 'snapshot') {
        if (first) firstPaint();
        else { repaint(); fx.modalSync({ upsert: ctx.D.all }); }
      }
      else { fx.dataChanged(msg); fx.modalSync(msg); fx.drawEdgesSoon(30); }
      writeOwnData();
      break;
    }
  }
}
export function resync() {
  if (ctx.proto.inFlight) return;
  ctx.proto.inFlight = true;
  const seq = ++ctx.resyncSeq, life = ctx.life;
  const current = () => ctx.life === life && !life.disposed && seq === ctx.resyncSeq;
  return ctx.push('build-resync', {}).then(reply => {
    if (!current()) return;
    ctx.proto.inFlight = false; receive(reply);
  }, () => { if (current()) ctx.proto.inFlight = false; });
}
function onServerURL({ state }) {
  const view = S.view, span = S.span, ticket = S.ticket;
  fromServer(state);
  if (ticket !== S.ticket) fx.syncTicket(S.ticket);
  renderChrome();
  if (view !== S.view && !S.loading) fx.viewport();
  fx.relayout(); fx.update();
  if (span !== S.span || view !== S.view) fx.jumpNow(true);
}
export function createBuildHomeHook() {
  return {
    mounted() {
      let urlState;
      try { urlState = JSON.parse(this.el.dataset.urlState || '{}'); } catch { urlState = {}; }
      resetState(urlState); seedDaemon(this.el.dataset.daemon);
      ctx.root = this.el; ctx.life = createLife(); ctx.resync = resync;
      ctx.push = (e, p) => this.pushEvent(e, p); ctx.reload = () => location.reload();
      this.buildLife = ctx.life;
      this.buildActive = shell();
      if (!this.buildActive) return;
      fx.wireTrees();
      fx.renderTools(); fx.initModal();
      writeOwnData();
      this.handleEvent('build-ticket-control', controlMessage);
      this.handleEvent('build-conversation', msg => fx.receiveConversation(msg));
      this.handleEvent('build-ticket-doc', applyDoc); this.handleEvent('build-queue-add', applyQueueAdd);
      this.handleEvent('send-status', msg => fx.sendStatus(msg));
      this.handleEvent('modal:command', msg => fx.renderCommand(msg));
      this.handleEvent('build-diff', receive); this.handleEvent('build:url', onServerURL);
      showServerState(this.el.dataset); resync();
    },
    updated() { if (this.buildActive) { writeOwnData(); showServerState(this.el.dataset); } },
    disconnected() {
      if (!this.buildActive) return;
      ctx.socket = 'down'; ctx.proto.inFlight = false; ctx.resyncSeq++; writeOwnData(); fx.renderOffline();
    },
    reconnected() {
      if (!this.buildActive) return;
      ctx.socket = 'up'; writeOwnData(); resync(); flushURL(); fx.renderOffline(); fx.reconnectConversation(); reconnectDoc();
    },
    destroyed() {
      this.buildLife?.dispose();
      if (ctx.life === this.buildLife) { ctx.proto.inFlight = false; ctx.resyncSeq++; }
    },
  };
}
