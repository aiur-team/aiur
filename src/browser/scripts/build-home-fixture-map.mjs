const labels = { claude: 'Claude', codex: 'Codex', deepseek: 'DeepSeek', kimi: 'Kimi' };
const logoKeys = { 'assets/claude-symbol.svg': 'claude', 'assets/codex-color.svg': 'codex',
  'assets/kimi-logo.png': 'kimi', 'assets/deepseek-logo.png': 'deepseek' };
const sections = ['hist', 'now', 'plan', 'nq'];
const duration = text => [...text.matchAll(/(\d+)([dhm])/g)].reduce((ms, [, n, unit]) => ms + Number(n) * { d: 86400000, h: 3600000, m: 60000 }[unit], 0);
const time = (obj, key) => obj[key] == null ? null : Math.trunc(obj[key]);
const optional = (obj, key) => obj[key] ?? null;

const stats = value => value == null ? null : {
  ...value, done_min: value.done, pct: value.total === 0 ? null : value.pct,
  pct_min: value.total === 0 ? null : value.pct, baseline: true,
  reasons: value.total === 0 ? ['no_weight'] : [],
};

export function mapRawToPayload({ meta, data, usage, daemon }, { featureStats = {} } = {}) {
  const id = value => value.replace(/^AIUR-/, '');
  const window = win => win ? { acc: win.acc,
    reset_at: Object.hasOwn(win, 'reset_at') ? time(win, 'reset_at') : win.reset == null ? null : meta.now + duration(win.reset),
    win: optional(win, 'win') } : null;
  const provider = p => ({ name: p.name, logo: Object.hasOwn(logoKeys, p.logo) ? logoKeys[p.logo] : Object.hasOwn(labels, p.logo) ? p.logo : null,
    mono: optional(p, 'mono'), hue: optional(p, 'hue'),
    tag: optional(p, 'tag'), accounts: optional(p, 'accounts'), session: window(p.session), weekly: window(p.weekly),
    credits: optional(p, 'credits'), none: p.none ?? false, icon: optional(p, 'icon'),
    lines: p.lines ? p.lines.map(line => ({ ...window(line), tag: line.tag, tip: line.tip,
      hold_until: time(line, 'hold_until') })) : null,
    stale: p.stale ?? false, observed_at: time(p, 'observed_at'), note: optional(p, 'note') });
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
    features: Object.fromEntries(Object.entries(data.features).map(([k, f]) => [k, { ...f, from: time(f, 'from'), to: Number.isFinite(f.to) ? Math.trunc(f.to) : null, stats: stats(featureStats[k]) }])),
    order: data.order, counts: Object.fromEntries(data.order.map(k => [k, data.counts[k] ?? 0])),
    sections: Object.fromEntries(sections.map(sec => [sec, data[sec].map(row)])),
    history: { from: null, more: false, total: data.hist.length, undated: 0, tz: meta.tz },
    sources: Object.fromEntries(['history', 'features', 'queue', 'agents', 'index'].map(k => [k, { state: 'ok', observed_at: meta.now, reason: null }])),
    usage: { state: 'authorized', observed_at: meta.now,
      apis: [provider({ name: 'GitHub', icon: 'github', lines: usage.apis.filter(a => ['core', 'gql'].includes(a.tag))
        .map(a => ({ ...a, acc: [a.pct ?? null], tip: a.rows })) })],
      providers: usage.models.map(provider) }, daemon };
}
