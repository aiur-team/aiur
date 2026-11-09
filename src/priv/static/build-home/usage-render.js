import { esc } from './dom.js';
import { I } from './icons.js';
import { LOGOS } from './logos.js';
const ICONS = Object.freeze(Object.assign(Object.create(null), { github: I.github, bars: I.bars }));
const remainingTone = p => p <= 10 ? ' max' : p <= 20 ? ' hi' : '';
const no = text => `<span class="ax-no">${esc(text)}</span>`;
export function fmtLeft(ms) {
  const m = Math.floor(Math.max(0, ms) / 60000), h = Math.floor(m / 60), d = Math.floor(h / 24);
  if (h < 1) return `${m}m`;
  if (d < 1) return `${h}h ${String(m % 60).padStart(2, '0')}m`;
  return `${d}d` + (h % 24 ? ` ${h % 24}h` : '');
}
function fmtAge(ms) {
  const seconds = Math.floor(Math.max(0, ms) / 1000);
  return seconds < 60 ? `${seconds}s` : fmtLeft(ms);
}
export function avgKnown(acc) {
  const known = acc.filter(Number.isInteger);
  return known.length ? Math.round(known.reduce((a, b) => a + b, 0) / known.length) : null;
}
function bar(acc) {
  return '<span class="ax-bar">' + (acc.length ? acc : [null]).map(p => p === null ? '<span class="ax-seg none"></span>' :
    `<span class="ax-seg"><i class="${p ? '' : 'z'}${remainingTone(p)}" style="width:${p}%"></i></span>`).join('') + '</span>';
}
function whoH(p) {
  const logo = LOGOS[p.logo], icon = ICONS[p.icon];
  const mono = p.mono ?? p.name.slice(0, 1).toUpperCase();
  const image = logo ? `<img class="${logo.fill ? 'fill' : ''}" src="${logo.src}" alt="">` : icon ? `<span class="ax-ic">${icon}</span>` :
    `<span class="ax-mono"${Number.isFinite(p.hue) ? ` style="background:oklch(.6 .16 ${p.hue})"` : ''}>${esc(mono)}</span>`;
  return `<div class="ax-who" title="${esc(p.name)}">${image}<b>${esc(p.name)}</b>${p.accounts ? `<span class="ax-x">×${p.accounts.length}</span>` : ''}</div>`;
}
const winTip = (w, label, n) => [[`${label} window${w.win == null ? '' : ' ' + w.win}`, n == null ? 'not observed' : `${n}% left`]];
// One full-width line per login, stacked; the login name lives in the tooltip and aria-label.
const accountLines = (p, w, label) => p.accounts.map((name, i) => {
  const n = w.acc[i] ?? null;
  return { ...w, acc: [n], pct: n, reset_at: w.resets?.[i] ?? w.reset_at, bar: bar([n]), head: `${p.name} ${name}`, rows: winTip(w, label, n), cls: i ? ' acct' : '' };
});
function tip(p, o, now) {
  const ended = o.reset_at != null && now !== null && o.reset_at <= now;
  const reset = o.reset_at != null && now !== null && !ended ? fmtLeft(o.reset_at - now) : null;
  const stale = Boolean(p.stale || ended), rows = [...o.rows];
  let head = o.head + (reset ? ` · ${o.renew ? 'renews' : 'resets'} in ${reset}` : '');
  if (stale) { head += ' · stale'; rows.push(['Observed', p.observed_at == null || now === null ? 'never' : fmtLeft(now - p.observed_at) + ' ago']); }
  if (p.snapshot_observed_at != null && now !== null) rows.push(['Snapshot age', fmtAge(now - p.snapshot_observed_at) + ' ago']);
  if (now !== null && o.hold_until > now) rows.push(['Held for', fmtLeft(o.hold_until - now)]);
  if (p.note != null && !o.none) rows.push(['Status', p.note]);
  return { ended, reset, head, rows };
}
function lineHTML(p, o, key, now) {
  const { ended, reset, head, rows } = tip(p, o, now);
  const right = o.right ?? (reset ? `<span>${reset}${o.win == null ? '' : `<em>/${esc(o.win)}</em>`}</span>${I.cycle}` : no(ended ? 'window ended' : 'reset unknown'));
  const aria = head + '. ' + rows.map(r => r.join(' ')).join('. ') + '.';
  const isApi = key.startsWith('api:');
  const tone = remainingTone;
  const percent = o.pct == null ? '' : `${o.pct}% left`;
  return `<div class="ax-ln${o.tag ? ' t' : ''}${o.cls ?? ''}${ended ? ' stale' : ''}" data-k="${key}" data-tip="${esc(JSON.stringify([head, rows]))}" tabindex="0" role="img" aria-label="${esc(aria)}">` +
    (o.tag ? `<span class="ax-tg">${esc(o.tag)}</span>` : '') + `<span class="ax-pc${tone(o.pct)}">${percent}</span>${o.bar}<span class="ax-rs">${right}</span></div>`;
}
function linesOf(p) {
  let lines;
  if (p.lines?.length) lines = p.lines.map(w => ({ ...w, pct: avgKnown(w.acc), bar: bar(w.acc), rows: w.tip,
    head: p.name + (w.tag === 'credits' ? '' : ' ' + (w.tag === 'gql' ? 'GraphQL' : w.tag)), renew: w.tag === 'credits' }));
  else if (p.credits) lines = [{ pct: p.credits.pct, bar: bar([p.credits.pct]),
    right: p.credits.left === 'unknown' ? no('unknown') : `<b class="ax-usd">${esc(p.credits.left)}</b>`, head: p.name + ' · credits', rows: p.credits.tip }];
  else if (!p.none && (p.session || p.weekly)) lines = [['Session', p.session], ['Weekly', p.weekly]].filter(([, w]) => w).flatMap(([label, w]) =>
    p.accounts ? accountLines(p, w, label) : [{ ...w, pct: avgKnown(w.acc), bar: bar(w.acc), head: p.name, rows: winTip(w, label, w.acc[0]) }]);
  else lines = [{ pct: null, bar: '<span class="ax-bar none"></span>', right: no(p.stale ? 'unavailable' : 'not observed'), head: p.name,
    rows: [['Limits', p.note ?? (p.none ? 'not reported by provider' : 'not observed')]], none: true }];
  return lines;
}
function rowHTML(p, key, now) {
  const lines = linesOf(p);
  return `<div class="ax-r2${p.stale ? ' stale' : ''}">${whoH(p)}<div class="ax-lns">${lines.map((o, i) => lineHTML(p, o, `${key}:${i}`, now)).join('')}</div></div>`;
}
function card(rows, type, title, now) {
  const noun = type === 'api' ? 'API' : 'model', count = `${rows.length} ${noun}${rows.length === 1 ? '' : 's'}`;
  const counter = type === 'api' ? `<span>${count}</span>` : `<span class="ax-cnt" id="ax-cnt">${count}</span>`;
  return `<section class="ax-uc ${type}"><div class="ax-uh">${title}${counter}</div><div class="ax-rows2">` +
    (rows.length ? rows.map((p, i) => rowHTML(p, `${type}:${i}`, now)).join('') : `<p class="ax-no">${type === 'api' ? 'No APIs observed' : 'No providers configured'}</p>`) + '</div></section>';
}
export function stripHTML(u, now) {
  if (u.state !== 'authorized') {
    const text = u.state === 'locked' ? `<b>${esc(u.accessible_name)}.</b> ${esc(u.reason)} ${esc(u.authentication_path)}` :
      `<b>Usage unavailable.</b> ${u.reason === 'usage_source_failed' ? 'The usage source failed.' : 'Reason unknown.'}`;
    return `<div class="ax-usage n0 lay-rows locked"><section class="ax-uc lock" role="status"><div class="ax-uh">Usage</div><p class="ax-no">${text}</p></section></div>`;
  }
  return `<div class="ax-usage n${u.providers.length} lay-${u.providers.length >= 7 ? 'cols' : 'rows'}">` +
    card(u.apis, 'api', 'APIs', now) + card(u.providers, 'mdl', 'Models', now) + '</div>';
}
// #7763: compact sidebar copy of the same line projection; keys and values match the header lines.
function navLine(p, o, i, key, now) {
  const { ended, head, rows } = tip(p, o, now);
  const value = o.pct != null ? `${o.pct}% left` : p.credits && p.credits.left !== 'unknown' ? p.credits.left : '';
  const title = [head, ...rows.map(r => r.join(': '))].join('\n');
  return `<div class="ax-nl${ended || p.stale ? ' stale' : ''}" data-k="${key}" title="${esc(title)}" role="img" aria-label="${esc(title.replaceAll('\n', '. '))}">` +
    `<span class="ax-nw">${i ? '' : whoH(p)}</span>${o.bar}<span class="ax-np${remainingTone(o.pct)}">${esc(value)}</span></div>`;
}
function navCard(rows, type, title, now) {
  if (!rows.length) return '';
  return `<section class="ax-nc" data-type="${type}"><div class="ax-nh">${title}</div>` +
    rows.map((p, r) => linesOf(p).map((o, i) => navLine(p, o, i, `${type}:${r}:${i}`, now)).join('')).join('') + '</section>';
}
export function navHTML(u, now) {
  return u.state === 'authorized' ? navCard(u.apis, 'api', 'APIS', now) + navCard(u.providers, 'mdl', 'MODELS', now) : '';
}
