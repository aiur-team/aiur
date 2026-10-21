import { esc } from '../dom.js';
import { I, MI } from '../icons.js';
import { fmtD, fmtT } from '../util.js';
import { modelInfo } from '../agents.js';

const EVK = { dep: [190, 'link'], commit: [255, 'commit'], prog: [null, 'prog'], pr: [300, 'pr'], review: [85, 'review'], comment: [220, 'chat'], merge: [150, 'merge'], fail: [25, 'warn'], cmd: [25, 'warn'], you: [0, 'pause'] };
function eventHTML(o) {
  const [hue, icon] = EVK[o.ev] || [0, 'chat'];
  return '<div class="cv-ev' + (['fail', 'cmd'].includes(o.ev) ? ' bad' : o.ev === 'you' ? ' mute' : '') + '" style="--eh:' + (o.ev === 'prog' ? Math.round(42 + o.pct * 1.03) : hue) + '"><span class="cv-evi">' + (I[icon] || MI[icon] || '') + '</span><b>' + esc(o.label) + '</b>' + (o.sub ? '<span class="cv-evs">' + esc(o.sub) + '</span>' : '') + (o.go ? '<button type="button" class="cv-go" data-goto="' + esc(o.go) + '">Open</button>' : '') + '<time>' + (o.at == null ? '—' : fmtT(o.at)) + '</time></div>';
}
function diffHTML(o) {
  return '<div class="cv-diff"><div class="cv-dh"><code>' + esc(o.file) + '</code><span><b class="a">+' + esc(o.add) + '</b> <b class="d">−' + esc(o.del) + '</b></span></div><pre>' + o.lines.map(l => '<span class="' + (l[0] === '+' ? 'a' : l[0] === '-' ? 'd' : '') + '">' + (['+', '-'].includes(l[0]) ? l[0] : ' ') + ' ' + esc(l[1]) + '</span>').join('') + '</pre></div>';
}
export function itemEl(o, model) {
  const m = typeof model === 'string' ? modelInfo(model) : model || modelInfo(null);
  let h;
  if (o.k === 'ev') h = eventHTML(o);
  else if (o.k === 'sys') h = '<div class="cv-sys">' + esc(o.text) + (o.at == null ? '' : ' · ' + fmtD(o.at) + ' ' + fmtT(o.at)) + '</div>';
  else if (o.k === 'op') h = '<div class="cv-op"><p>' + esc(o.text) + '</p><time>You' + (o.at == null ? '' : ' · ' + fmtT(o.at)) + '</time></div>';
  else if (o.k === 'say') h = '<div class="cv-say">' + (m.logo ? '<img src="' + esc(m.logo.src || m.logo) + '" alt="">' : '<span class="ax-mono" style="width:16px;height:16px;flex:none;border-radius:50%;font-size:.6rem" aria-hidden="true">' + esc(m.mono || '?') + '</span>') + '<p>' + esc(o.text) + '</p></div>';
  else if (o.k === 'tool') h = '<div class="cv-tool' + (o.bad ? ' bad' : '') + '"><span class="cv-tn">' + MI.tool + esc(o.name) + '</span><code>' + esc(o.arg) + '</code><span class="cv-tr">' + esc(o.res) + '</span></div>';
  else if (o.k === 'diff') h = diffHTML(o);
  else return null;
  const w = document.createElement('div'); w.innerHTML = h; const el = w.firstChild;
  el.dataset.k = o.k; el.dataset.eid = o.id; el.dataset.cursor = o.cursor || o.id;
  if (o.at == null && ['sys', 'op'].includes(o.k)) el.title = 'Time unknown';
  if (o.k === 'ev') { el.dataset.label = o.label; el.dataset.at = o.at == null ? '—' : fmtT(o.at); el.dataset.ev = o.ev; }
  return el;
}
