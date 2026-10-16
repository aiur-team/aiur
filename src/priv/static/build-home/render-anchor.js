import { ctx, LH } from './state.js';

const natural = () => ctx.secs.hist.el.offsetTop + ctx.L.secs.hist.h;
export function takeAnchor() {
  if (!ctx.L || !ctx.content) return null;
  const st = ctx.vp.scrollTop, nat = natural(), off = nat - st;
  if (off >= 0 && off <= ctx.vp.clientHeight) return { kind: 'band', off };
  const cards = [];
  for (const [sec, layout] of Object.entries(ctx.L.secs)) {
    for (const it of layout.items) {
      const uid = sec + ':' + it.t.id, top = ctx.secs[sec].el.offsetTop + it.y;
      if (ctx.R.has(uid) && top >= st + LH) cards.push({ uid, off: top - st });
    }
  }
  return { kind: 'cards', off, cards: cards.sort((a, b) => a.off - b.off).slice(0, 3) };
}
export function restoreAnchor(anchor) {
  if (!anchor || !ctx.L || !ctx.content) return;
  for (const card of anchor.cards ?? []) {
    const [sec, id] = card.uid.split(':');
    const it = ctx.L.secs[sec]?.items.find(it => it.t.id === id);
    if (it) { ctx.vp.scrollTop = ctx.secs[sec].el.offsetTop + it.y - card.off; return; }
  }
  ctx.vp.scrollTop = natural() - anchor.off;
}
