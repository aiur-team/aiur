export function chainsD(tickets, order = ['bugs', 'infra', 'unsorted']) {
  const byId = Object.create(null), children = Object.create(null);
  for (const t of tickets) byId[t.id] = { sec: 'plan', epic: 'bugs', num: 1, deps: [], ...t };
  for (const t of Object.values(byId)) {
    children[t.id] ||= [];
    for (const dep of t.deps) (children[dep] ||= []).push(t.id);
    for (const child of t.children || []) if (!(children[t.id] || []).includes(child)) children[t.id].push(child);
  }
  return { byId, children, order };
}

export function fixtureD(snapshot) {
  return chainsD(Object.values(snapshot.sections).flat(), snapshot.order);
}
