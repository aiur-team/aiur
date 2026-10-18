import { S, FKEYS } from './state.js';
export { colKey } from './layout.js';
import { colKey } from './layout.js';
const HIST_STATE = { done: 'merged', failed: 'failed', closed: 'closed', not_planned: 'not planned' };
export const tstate = t => t.sec === 'hist' ? (Object.hasOwn(HIST_STATE, t.status) ? HIST_STATE[t.status] : 'unknown') : t.sec === 'now' ? 'in progress' : t.sec === 'plan' ? (t.cue.held ? 'held' : (t.cue.waitAny || t.cue.failed || t.cue.blockedChain) ? 'blocked' : 'queued') : 'open';
export const astate = t => t.sec === 'now' ? t.agent?.state ?? 'none' : 'none';
export function match(t, state = S) {
  for (const k of FKEYS) {
    const sel = state.f[k]; if (!sel.length) continue;
    const v = k === 'type' ? t.type : k === 'model' ? (t.agent ? t.agent.model : 'none') : k === 'feature' ? t.feature : k === 'epic' ? colKey(t) : k === 'tstate' ? tstate(t) : astate(t);
    if (Array.isArray(v) ? !v.some(x => sel.includes(x)) : !sel.includes(v)) return false;
  }
  return true;
}
