import { esc } from '../dom.js';
import { I, MI } from '../icons.js';
import { fmtD, fmtT } from '../util.js';

// Port of the design's event row (J:1284, J:1341–1352); unknown time and unknown percent stay visibly unknown.
export const EVK = { dep: [190, 'link'], commit: [255, 'commit'], prog: [null, 'prog'], pr: [300, 'pr'], review: [85, 'review'], comment: [220, 'chat'], merge: [150, 'merge'], fail: [25, 'warn'], cmd: [25, 'warn'], you: [0, 'pause'] };
const ic = n => I[n] || MI[n] || '';
const known = o => o.ev !== 'prog' || Number.isInteger(o.pct);
export const evHue = o => o.ev === 'prog' ? Math.round(42 + o.pct * 1.03) : EVK[o.ev][0];
function sub(o) {
  if (o.sub) return o.sub;
  return o.ev === 'merge' && o.at != null ? fmtD(o.at) + ' ' + fmtT(o.at) : '';
}
// The dependency's number, from its label ("Dependency #N …"), else its id.
const depNum = o => (/#(\d+)/.exec(o.label || '') || [])[1] || o.go;
export function eventHTML(o) {
  const kind = EVK[o.ev] || EVK.comment, s = sub(o), at = o.at == null ? '—' : fmtT(o.at);
  const cls = ['fail', 'cmd'].includes(o.ev) ? ' bad' : o.ev === 'you' || !known(o) ? ' mute' : '';
  const time = o.at == null ? '<time title="Time unknown">—</time>' : '<time datetime="' + new Date(o.at).toISOString() + '">' + at + '</time>';
  const data = ' data-k="ev" data-eid="' + esc(o.id) + '" data-label="' + esc(o.label) + '" data-at="' + at + '" data-ev="' + esc(o.ev) + '"';
  return '<div class="cv-ev' + cls + '"' + (EVK[o.ev] && known(o) ? ' style="--eh:' + evHue(o) + '"' : '') + data + '><span class="cv-evi">' + ic(kind[1]).replace('<svg ', '<svg aria-hidden="true" ') + '</span><b>' + esc(o.label) + '</b>' +
    (s ? '<span class="cv-evs">' + esc(s) + '</span>' : '') +
    (o.go ? '<button type="button" class="cv-go" data-goto="' + esc(o.go) + '" aria-label="' + esc('Open #' + depNum(o) + (o.sub ? ' ' + o.sub : '')) + '">Open</button>' : '') + time + '</div>';
}
export function eventEl(o) {
  const w = document.createElement('div'); w.innerHTML = eventHTML(o); return w.firstChild;
}
