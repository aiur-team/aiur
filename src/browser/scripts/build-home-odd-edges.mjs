// Explicit expectations for states absent from the frozen design datasets.
export function oddEdges(live) {
  const repository = { owner: 'aiur-team', repository: 'aiur' };
  const at = day => Date.UTC(2026, 8, day, 10);
  const definitions = [
    [1, [2]], [2, [1]], [3, [4]], [4, [5]], [5, [3]], [7, [7]],
    [10, [], 'completed', at(3)], [12, [10], 'completed', at(1)],
    [14, [999]], [16, [10], 'completed', 'unknown'],
  ];
  const rows = definitions.map(([number, deps, reason = 'none', end = 'none']) => ({
    number, lifecycle: { state: reason === 'none' ? 'open' : 'closed', state_reason: reason }, end,
    blocked_by: deps.map(number => ({ ...repository, number })), blocked_by_complete: true,
  }));
  const expected = Object.fromEntries(rows.map(r => [r.number, {
    deps: r.blocked_by.filter(d => d.number !== r.number && d.number !== 999).map(d => String(d.number)),
    children: rows.filter(t => t.number !== r.number && t.blocked_by.some(d => d.number === r.number)).map(t => String(t.number)),
    dep_states: Object.fromEntries(r.blocked_by.filter(d => d.number !== r.number && d.number !== 999)
      .map(d => [String(d.number), r.number === 12 ? 'terminal_unsatisfied' : d.number === 10 ? 'cleared' : 'blocking'])),
    deps_missing: r.number === 14 ? 1 : 0,
  }]));
  const template = live.sections.nq[0];
  const tickets = rows.map((r, ord) => ({ ...template, id: String(r.number), num: r.number,
    title: `Odd dependency #${r.number}`, sec: Number.isInteger(r.end) ? 'hist' : 'nq', ord,
    status: r.lifecycle.state === 'closed' ? 'done' : 'open', end: Number.isInteger(r.end) ? r.end : null,
    start: null, start_src: 'unknown', cue: null, wave: null, qpos: null, ...expected[r.number] }));
  const snapshot = { ...live, sections: { hist: tickets.filter(t => t.sec === 'hist'), now: [], plan: [], nq: tickets.filter(t => t.sec === 'nq') },
    history: { ...live.history, total: 2 } };
  return { snapshot, history: { repository, rows, expected } };
}
