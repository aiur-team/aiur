// J:486–496: every live row gets a stack, independently of lane filters.
export function bandLayout(D, S, dims, { ch, gap, pphG, CH, gantt, det, lanes, laneWidth }) {
  const band = { items: [], h: 0 }, stack = {}, BH = 42;
  const BL = D.now.slice().sort((a, b) => (D.order ?? []).indexOf(a.epic || 'unsorted') - (D.order ?? []).indexOf(b.epic || 'unsorted') || a.num - b.num);
  // #7687: band columns are planned-lane wide (mini/bar capped at 70 as in place()), so zoom and flow resize LIVE cards like every other card.
  const lane = laneWidth(dims, lanes, S.flow), avail = dims.vpW - dims.gut - 14, bg = lane.gap;
  const cw = !S.flow && ['mini', 'bar'].includes(det) ? Math.min(lane.cw, 70) : lane.cw;
  const BK = Math.max(1, Math.min(BL.length || 1, Math.floor((avail + bg) / (cw + bg))));
  band.BK = BK; band.cw = cw; band.bg = bg;
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
