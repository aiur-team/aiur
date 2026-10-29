// Server estimates are authoritative; missing complexity has no client fallback.
export const estHours = t => {
  const hours = t.override ? t.override.hours : t.est;
  return Number.isFinite(hours) && hours > 0 ? hours : null;
};
export const estLabel = t => { const h = estHours(t); return h == null ? '—' : '≈' + h + 'h'; };
export function etaLabel(D) {
  const q = D.sources.queue.state, part = q === 'incomplete' ? '≥' : '';
  const toGo = q === 'unavailable' ? '—' : part + String(D.plan.length + D.now.length);
  const cap = D.capacity && D.capacity.max;
  const hs = D.plan.map(estHours), known = hs.filter(h => h != null);
  let eta = '—', title = '';
  if (q === 'unavailable') title = 'Queue unavailable';
  else if (!D.plan.length) title = '';
  else if (!cap) title = 'Agent cap unknown';
  else if (D.sources.estimates?.state === 'unavailable') title = 'Estimates unavailable';
  else if (!known.length) title = 'No planned ticket has an estimate';
  else {
    const h = Math.max(1, Math.round(known.reduce((s, x) => s + x, 0) / cap));
    const miss = hs.length - known.length;
    eta = (miss || part || D.now.length ? '≥' : '') + h + 'h';
    title = (miss ? miss + ' planned without an estimate · ' : '') + 'at ' + cap + ' agents';
  }
  return { text: toGo + ' to go · ETA ' + eta + (D.capacity?.stale ? ' · cap stale' : ''), title };
}
