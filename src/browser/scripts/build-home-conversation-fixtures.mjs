// Product-only edge cases stay separate from the frozen design datasets.
export function conversationStates(now) {
  const say = (id, text, at = now) => ({ id, k: 'say', text, at });
  const view = (state, entries = [], rest = {}) => ({ state, entries, observed_at: now, live: state === 'live' || state === 'known_empty', ...rest });
  return {
    not_retained: view('not_retained'),
    known_empty: view('known_empty'),
    stale: view('stale', [say('stale:0', 'A retained message')], { observed_at: now - 7 * 60000 }),
    unavailable: view('unavailable'),
    restart_unknown: view('restart_unknown'),
    ended: view('ended', [say('ended:0', 'Completed')]),
    unknown_time: view('ended', [{ id: 'unknown:0', k: 'sys', text: 'Picked up', at: null }, { id: 'unknown:1', k: 'op', text: 'Keep going', at: null }]),
    unknown_model: view('ended', [say('model:0', 'Unknown model')]),
    hostile: view('ended', [say('hostile:0', '<img src=x onerror="window.__xss=1">')]),
    paged: view('ended', Array.from({ length: 600 }, (_, n) => say('page:' + n, 'Entry ' + n, now - (600 - n) * 1000))),
    kinds: view('ended', [
      { id: 'kind:0', k: 'sys', text: 'Picked up', at: now }, say('kind:1', 'Checking the code'),
      { id: 'kind:2', k: 'op', text: 'Please continue', at: now },
      { id: 'kind:3', k: 'tool', name: 'bash', arg: 'mix test', res: '✗ exit 2', bad: true, at: now },
      { id: 'kind:4', k: 'diff', file: 'sample.ex', lines: [['+', 'changed']], add: 1, del: 0, at: now },
      { id: 'kind:5', k: 'ev', ev: 'dep', label: 'Dependency merged', sub: 'Ready to consume', at: now },
    ]),
  };
}
export function designConversations(data, kind, convoFor) {
  return Object.fromEntries(Array.from(data.all).filter(t => t.agent && t.start != null).map(t => [t.id.replace('AIUR-', ''),
    Array.from(convoFor(kind, t.id).items, (o, n) => ({ ...o, ...(o.go ? { go: o.go.replace('AIUR-', '') } : {}), id: 'd:' + n, at: Math.round(o.at) }))]));
}
