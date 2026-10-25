import { ctx, S, fx, rmOn, isVisible } from './state.js';
import { $ } from './dom.js';

export function syncSB() {
  const { vp, root } = ctx, sb = $('#bd-sb', root), th = $('i', sb);
  const sh = vp.scrollHeight, ch = vp.clientHeight;
  if (sh <= ch + 1) { sb.classList.add('off'); return; }
  sb.classList.remove('off');
  const track = sb.clientHeight, h = Math.max(28, track * ch / sh);
  th.style.height = h + 'px';
  th.style.transform = 'translateY(' + Math.min(1, vp.scrollTop / (sh - ch)) * (track - h) + 'px)';
}
export function shell() {
  const { root, life } = ctx;
  for (const id of ['bd-usage', 'bd-offline', 'bd-fh', 'bd-tools-l', 'bd-filters', 'bd-tools', 'bd-vp', 'bd-sb', 'bd-tree', 'bd-status']) {
    if (!$('#' + id, root)) return fail(id);
  }
  const sb = $('#bd-sb', root), th = $(':scope > i', sb), vp = ctx.vp = $('#bd-vp', root);
  if (!th) return fail('bd-sb > i');
  function fail(id) {
    console.error('BuildHome missing host: ' + id);
    root.dataset.buildHomeHook = 'failed';
    return false;
  }
  life.on(vp, 'scroll', () => {
    syncSB(); sb.classList.add('act');
    life.later('sb-active', 700, () => sb.classList.remove('act'));
  }, { passive: true });
  life.observe(vp, syncSB); life.every(500, syncSB);
  let dragOffs = [];
  const endDrag = () => { sb.classList.remove('drag'); dragOffs.splice(0).forEach(off => off()); };
  life.on(th, 'pointerdown', e => {
    endDrag(); e.preventDefault(); th.setPointerCapture(e.pointerId);
    const y0 = e.clientY, s0 = vp.scrollTop;
    const k = (vp.scrollHeight - vp.clientHeight) / Math.max(1, sb.clientHeight - th.offsetHeight);
    sb.classList.add('drag');
    dragOffs = [
      life.on(th, 'pointermove', ev => { vp.scrollTop = s0 + (ev.clientY - y0) * k; }),
      ...['pointerup', 'pointercancel', 'lostpointercapture'].map(type => life.on(th, type, endDrag)),
    ];
  });
  life.on(sb, 'pointerdown', e => {
    if (e.target !== sb) return;
    const r = sb.getBoundingClientRect();
    vp.scrollTop = (e.clientY - r.top) / r.height * (vp.scrollHeight - vp.clientHeight);
  });
  const motion = () => root.classList.toggle('rm', rmOn());
  motion(); life.media('(prefers-reduced-motion: reduce)', motion);
  life.on(document, 'click', e => {
    if (!ctx.lockId || !e.target.isConnected || e.target.closest('.bd-lt, .bd-tree, .bd-eh, #tk-backdrop')) return;
    const c = e.target.closest('.bd-card');
    if (c && fx.chainOf(ctx.lockId).has(c.dataset.id)) return;
    fx.unlock();
  });
  life.on(document, 'keydown', e => {
    if (e.key !== 'Escape' || e.defaultPrevented || document.querySelector('#tk-backdrop.show')) return;
    if (S.pop) { const g = S.pop; S.pop = null; fx.renderFilters(); $('[data-g="' + g + '"]', root)?.focus(); return; }
    if (!$('#bd-tree', root).hidden) fx.closeTree(); else if (ctx.lockId) fx.unlock();
  }, { capture: true });
  life.on(vp, 'scroll', () => {
    fx.liveGuard(); fx.markScrolling(); life.frame('scroll-update', () => fx.update());
  }, { passive: true });
  // #4827: on phones the fixed bottom nav covers the board's end, so reaching it scrolls the page clear; the shell's bottom padding leaves room.
  const nav = document.querySelector('.sidenav');
  life.on(vp, 'scroll', () => {
    if (!nav || getComputedStyle(nav).position !== 'fixed' || vp.scrollTop + vp.clientHeight < vp.scrollHeight - 1) return;
    const over = vp.getBoundingClientRect().bottom - nav.getBoundingClientRect().top;
    if (over > 0) window.scrollBy(0, over);
  }, { passive: true });
  let lastST = -1;
  life.every(250, () => {
    fx.flushLive();
    if (S.loading || !ctx.L || !isVisible()) return;
    if (vp.scrollTop !== lastST) { lastST = vp.scrollTop; fx.update(); }
  });
  life.on(document, 'click', e => {
    if (S.pop && !e.target.closest('.bd-pop') && !e.target.closest('.bd-fg')) { S.pop = null; fx.renderFilters(); }
  });
  life.on(window, 'resize', () => life.later('resize', 140, () => {
    if (ctx.inited && isVisible() && !S.loading) {
      const f = vp.scrollTop / Math.max(1, vp.scrollHeight);
      fx.relayout(); vp.scrollTop = f * vp.scrollHeight; fx.update();
    }
  }));
  syncSB();
  return true;
}
