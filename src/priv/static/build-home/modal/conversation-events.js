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
export function eventEl(o) {
  const kind = EVK[o.ev] || EVK.comment, s = sub(o);
  const cls = ['fail', 'cmd'].includes(o.ev) ? ' bad' : o.ev === 'you' || !known(o) ? ' mute' : '';
  const time = o.at == null ? '<time title="Time unknown">—</time>' : '<time datetime="' + new Date(o.at).toISOString() + '">' + fmtT(o.at) + '</time>';
  const w = document.createElement('div');
  w.innerHTML = '<div class="cv-ev' + cls + '"' + (EVK[o.ev] && known(o) ? ' style="--eh:' + evHue(o) + '"' : '') + '><span class="cv-evi">' + ic(kind[1]) + '</span><b>' + esc(o.label) + '</b>' +
    (s ? '<span class="cv-evs">' + esc(s) + '</span>' : '') +
    (o.go ? '<button type="button" class="cv-go" data-goto="' + esc(o.go) + '">Open</button>' : '') + time + '</div>';
  const el = w.firstChild;
  el.querySelector('.cv-evi svg')?.setAttribute('aria-hidden', 'true');
  if (o.go) el.querySelector('.cv-go').setAttribute('aria-label', 'Open #' + o.go + (o.sub ? ' ' + o.sub : ''));
  el.dataset.k = 'ev'; el.dataset.eid = o.id; el.dataset.label = o.label; el.dataset.at = o.at == null ? '—' : fmtT(o.at); el.dataset.ev = o.ev;
  return el;
}
