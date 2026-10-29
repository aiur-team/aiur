import { nowMs } from '../clock.js';
import { fmtD, fmtT } from '../util.js';

export const notRetainedCue = () => '<p class="bm-cue">Conversation not retained</p>';
const date = at => Number.isFinite(at) ? ' ' + fmtD(at) + ' ' + fmtT(at) : '';
export function footer(t, msg) {
  if (msg.state === 'stale') {
    const now = nowMs(), at = msg.observed_at;
    return { text: 'Live updates unavailable · ' + (Number.isFinite(now) && Number.isFinite(at) ? 'read ' + Math.max(0, Math.floor((now - at) / 60000)) + 'm ago' : 'read time unknown') };
  }
  if (msg.state === 'restart_unknown') return { text: 'Live state unknown after a restart' };
  if (msg.state === 'unavailable') return { text: 'Conversation unavailable' };
  if (t.sec === 'hist') return {
    text: 'Session ended' + (t.status === 'failed' ? ' · PR closed' : t.status === 'done' ? ' · merged' : '') + date(t.end),
    title: !Number.isFinite(t.end) ? (t.status === 'done' ? 'Merge time unknown' : 'End time unknown') : '',
  };
  if (msg.state === 'ended') return { text: 'Session ended' + date(msg.entries?.at(-1)?.at) };
  return { text: '' };
}
