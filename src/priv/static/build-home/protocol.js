// State is null before the first snapshot; resyncing is the hook's single-flight flag.
export function decide(state, msg) {
  if (msg.v !== 1) return 'reload';
  if (msg.kind === 'error') return 'ignore';
  const loaded = state?.epoch != null;
  if (msg.kind === 'snapshot') {
    return !loaded || msg.epoch !== state.epoch || msg.generation > state.generation ? 'apply' : 'ignore';
  }
  if (msg.kind === 'earlier') return loaded && msg.epoch === state.epoch ? 'apply' : 'ignore';
  if (msg.kind !== 'diff' || !loaded) return 'ignore';
  if (msg.epoch !== state.epoch || msg.generation > state.generation + 1) return state.resyncing ? 'ignore' : 'resync';
  return msg.generation === state.generation + 1 ? 'apply' : 'ignore';
}

export function intake(snapshot) {
  const sort = rows => [...rows].sort((a, b) => a.ord - b.ord || (a.num ?? 0) - (b.num ?? 0));
  const sections = Object.fromEntries(Object.entries(snapshot.sections).map(([key, rows]) => [key, sort(rows)]));
  const all = ['hist', 'now', 'plan', 'nq'].flatMap(key => sections[key]);
  const byId = Object.fromEntries(all.map(row => [row.id, row]));
  const children = {};
  for (const row of all) for (const dep of row.deps) (children[dep] ??= []).push(row.id);
  const features = Object.fromEntries(Object.entries(snapshot.features).map(([key, feature]) => [key, { ...feature, to: feature.to === null ? Infinity : feature.to }]));
  return { epics: snapshot.epics, features, order: snapshot.order, counts: snapshot.counts, ...sections, all, byId, children };
}

export const esc = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
