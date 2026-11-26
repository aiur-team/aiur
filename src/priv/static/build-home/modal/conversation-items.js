import { esc } from '../dom.js';
import { MI } from '../icons.js';
import { fmtT } from '../util.js';
import { eventEl } from './conversation-events.js';
import { modelInfo } from '../agents.js';

function timestamp(o) { return o.at == null ? '' : '<time class="cv-time" datetime="' + new Date(o.at).toISOString() + '">' + esc(fmtT(o.at)) + '</time>'; }
function toolHTML(o) {
  const name = o.k === 'diff' ? 'edit' : o.name;
  const arg = o.k === 'diff' ? o.file : o.arg;
  const detail = o.k === 'diff' ? o.lines.map(l => l[1]).join('\n') : o.res;
  const summary = o.summary || [arg, o.res].filter(Boolean).join(' · ');
  const state = o.bad ? (o.status || 'Failed') : '';
  return '<div class="cv-tool-row' + (o.bad ? ' bad' : '') + '"><details class="cv-tool"><summary><span class="cv-tn">' + MI.tool + esc(name) + '</span><span class="cv-tool-summary" title="' + esc(summary) + '">' + esc(summary || 'No result') + '</span>' + (state ? '<span class="cv-tool-status" title="Tool failed">' + esc(state) + '</span>' : '') + '</summary><div class="cv-tool-detail"><code>' + esc(arg || '') + '</code><pre>' + esc(detail || 'No output') + '</pre></div></details>' + timestamp(o) + '</div>';
}
// Server event rows (`ev:` ids, including their sys rows) are never transcript page cursors.
export const cursorOf = o => String(o.id).startsWith('ev:') ? null : o.cursor || o.id;
export function itemEl(o, model) {
  const m = typeof model === 'string' ? modelInfo(model) : model || modelInfo(null);
  let h;
  if (o.k === 'ev') return eventEl(o);
  if (o.k === 'sys') h = '<div class="cv-sys">' + esc(o.text) + timestamp(o) + '</div>';
  else if (o.k === 'op') h = '<div class="cv-op"><p>' + esc(o.text) + '</p><span class="cv-meta">You ' + timestamp(o) + '</span></div>';
  else if (o.k === 'say') h = '<div class="cv-say">' + (m.logo ? '<img src="' + esc(m.logo.src || m.logo) + '" alt="">' : '<span class="ax-mono" style="width:16px;height:16px;flex:none;border-radius:50%;font-size:.6rem" aria-hidden="true">' + esc(m.mono || '?') + '</span>') + '<p>' + esc(o.text) + '</p></div>';
  else if (o.k === 'tool' || o.k === 'diff') h = toolHTML(o);
  else return null;
  const w = document.createElement('div'); w.innerHTML = h; const el = w.firstChild;
  el.dataset.k = o.k; el.dataset.eid = o.id; el.dataset.at = o.at == null ? '—' : fmtT(o.at);
  const cursor = cursorOf(o); if (cursor) el.dataset.cursor = cursor;
  if (o.at == null && ['sys', 'op'].includes(o.k)) el.title = 'Time unknown';
  return el;
}
