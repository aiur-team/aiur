const labels = { claude: 'Claude', codex: 'Codex', deepseek: 'DeepSeek', kimi: 'Kimi' };
const sections = ['hist', 'now', 'plan', 'nq'];
const duration = text => [...text.matchAll(/(\d+)([dhm])/g)].reduce((ms, [, n, unit]) => ms + Number(n) * { d: 86400000, h: 3600000, m: 60000 }[unit], 0);
const time = (obj, key) => obj[key] == null ? null : Math.trunc(obj[key]);
const optional = (obj, key) => obj[key] ?? null;

export function mapRawToPayload({ meta, data, usage, daemon }) {
  const id = value => value.replace(/^AIUR-/, '');
  const window = win => win ? { acc: win.acc, reset_at: meta.now + duration(win.reset), win: win.win } : null;
  const provider = p => ({ name: p.name, logo: optional(p, 'logo'), mono: optional(p, 'mono'), hue: optional(p, 'hue'),
    tag: optional(p, 'tag'), accounts: optional(p, 'accounts'), session: window(p.session), weekly: window(p.weekly),
    credits: optional(p, 'credits'), none: p.none ?? false });
  const row = (t, ord) => ({ id: id(t.id), num: t.num, title: t.title, type: t.type, epic: optional(t, 'epic'), feature: optional(t, 'feature'),
    also: t.also, cx: optional(t, 'cx'), pts: optional(t, 'pts'), sec: t.sec, ord,
    start: time(t, 'start'), end: time(t, 'end'), created: time(t, 'created'), status: t.status,
    pct: optional(t, 'pct'), agent: t.agent ? { ...t.agent, name: Object.hasOwn(labels, t.agent.model) ? labels[t.agent.model] : null } : null, est: optional(t, 'est'), override: t.override ? { hours: t.override.hours, reason: t.override.reason, by: t.override.by ?? null, at: time(t.override, 'at') } : null,
    added: t.added ?? false, deps: t.deps.map(id), wave: optional(t, 'wave'), qpos: optional(t, 'qpos'),
    cue: t.cue ? { held: optional(t.cue, 'held'), promoted: t.cue.promoted ? meta.now - duration(t.cue.promoted) : null,
      wait: optional(t.cue, 'wait'), waitAny: t.cue.waitAny ?? false, failed: optional(t.cue, 'failed'), blockedChain: t.cue.blockedChain ?? false } : null,
    pr: null });
  return { v: 1, kind: 'snapshot', epoch: 'fixture', generation: 0, now: meta.now, writable: true,
    repo: { url: 'https://github.com/example/aiur-fixture/' }, epics: data.epics,
    features: Object.fromEntries(Object.entries(data.features).map(([k, f]) => [k, { ...f, from: time(f, 'from'), to: Number.isFinite(f.to) ? Math.trunc(f.to) : null }])),
    order: data.order, counts: Object.fromEntries(data.order.map(k => [k, data.counts[k] ?? 0])),
    sections: Object.fromEntries(sections.map(sec => [sec, data[sec].map(row)])),
    history: { from: null, more: false, total: data.hist.length, undated: 0, tz: meta.tz },
    sources: Object.fromEntries(['history', 'features', 'queue', 'agents', 'index'].map(k => [k, { state: 'ok', observed_at: meta.now, reason: null }])),
    usage: { state: 'authorized', observed_at: meta.now,
      apis: usage.apis.map(a => provider({ name: 'GitHub', tag: a.tag, session: { acc: [a.pct], reset: a.reset, win: a.win } })),
      providers: usage.models.map(provider) }, daemon };
}
