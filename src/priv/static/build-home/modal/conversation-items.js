import { esc } from '../dom.js';
import { MI } from '../icons.js';
import { fmtD, fmtT } from '../util.js';
import { eventEl } from './conversation-events.js';
import { modelInfo } from '../agents.js';

function diffHTML(o) {
  return '<div class="cv-diff"><div class="cv-dh"><code>' + esc(o.file) + '</code><span><b class="a">+' + esc(o.add) + '</b> <b class="d">−' + esc(o.del) + '</b></span></div><pre>' + o.lines.map(l => '<span class="' + (l[0] === '+' ? 'a' : l[0] === '-' ? 'd' : '') + '">' + (['+', '-'].includes(l[0]) ? l[0] : ' ') + ' ' + esc(l[1]) + '</span>').join('') + '</pre></div>';
}
// Server event rows (`ev:` ids, including their sys rows) are never transcript page cursors.
export const cursorOf = o => String(o.id).startsWith('ev:') ? null : o.cursor || o.id;
export function itemEl(o, model) {
  const m = typeof model === 'string' ? modelInfo(model) : model || modelInfo(null);
  let h;
  if (o.k === 'ev') return eventEl(o);
  if (o.k === 'sys') h = '<div class="cv-sys">' + esc(o.text) + (o.at == null ? '' : ' · ' + fmtD(o.at) + ' ' + fmtT(o.at)) + '</div>';
  else if (o.k === 'op') h = '<div class="cv-op"><p>' + esc(o.text) + '</p><time>You' + (o.at == null ? '' : ' · ' + fmtT(o.at)) + '</time></div>';
  else if (o.k === 'say') h = '<div class="cv-say">' + (m.logo ? '<img src="' + esc(m.logo.src || m.logo) + '" alt="">' : '<span class="ax-mono" style="width:16px;height:16px;flex:none;border-radius:50%;font-size:.6rem" aria-hidden="true">' + esc(m.mono || '?') + '</span>') + '<p>' + esc(o.text) + '</p></div>';
  else if (o.k === 'tool') h = '<div class="cv-tool' + (o.bad ? ' bad' : '') + '"><span class="cv-tn">' + MI.tool + esc(o.name) + '</span><code>' + esc(o.arg) + '</code><span class="cv-tr">' + esc(o.res) + '</span></div>';
  else if (o.k === 'diff') h = diffHTML(o);
  else return null;
  const w = document.createElement('div'); w.innerHTML = h; const el = w.firstChild;
  el.dataset.k = o.k; el.dataset.eid = o.id;
  const cursor = cursorOf(o); if (cursor) el.dataset.cursor = cursor;
  if (o.at == null && ['sys', 'op'].includes(o.k)) el.title = 'Time unknown';
  return el;
}
