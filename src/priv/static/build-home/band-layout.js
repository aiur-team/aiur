// J:486–496: every live row gets a stack, independently of epic filters.
export function bandLayout(D, S, dims, { ch, gap, pphG, CH, gantt }) {
  const band = { items: [], h: 0 }, stack = {}, BH = 42;
  const BL = D.now.slice().sort((a, b) => (D.order ?? []).indexOf(a.epic || 'unsorted') - (D.order ?? []).indexOf(b.epic || 'unsorted') || a.num - b.num);
  const BK = Math.max(1, Math.min(BL.length || 1, Math.floor((dims.vpW - dims.gut - 14) / 230)));
  band.BK = BK;
  if (!S.liveMin) BL.forEach((t, n) => {
    const k = 'b' + (n % BK), y0 = stack[k] ?? BH;
    // #7446: outside gantt, live cards take the board's tier (L.det) and row height like every other card.
    const gt = S.view === 'gantt', h = gt ? gantt.bandHeight(t, { pphG, CH }) : ch;
    band.items.push({ t, key: k, y: y0, h, sec: 'now', gt });
    stack[k] = y0 + h + gap;
  });
  const maxY = Math.max(0, ...Object.values(stack));
  band.h = S.liveMin ? 38 : maxY ? maxY + 12 - gap : BH + 44;
  return band;
}
