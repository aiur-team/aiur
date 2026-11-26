import taxonomy from './ticket-status.json' with { type: 'json' };
import { isUnfiled, queueText } from './unfiled.js';
const f = Object.freeze;
export const AST = f(Object.fromEntries(Object.entries(taxonomy.agent).map(([state, value]) => [state, f(value)])));
export const UNKNOWN_STATE = f(taxonomy.unknown);
export const agentState = s => typeof s === "string" && Object.hasOwn(AST, s) ? AST[s] : UNKNOWN_STATE;
export function ticketStatus(t) {
  if (t.sec === 'now') { const state = agentState(t.agent?.state); return { label: state.label, tone: state.cls || 'idle' }; }
  if (t.sec === 'hist') return Object.hasOwn(taxonomy.history, t.status) ? taxonomy.history[t.status] : { label: UNKNOWN_STATE.label, tone: 'idle' };
  if (t.sec === 'plan') return isUnfiled(t) ? taxonomy.sections.unfiled : { label: taxonomy.sections.plan.label + queueText(t), tone: taxonomy.sections.plan.tone };
  return t.sec === 'nq' ? taxonomy.sections.nq : { label: UNKNOWN_STATE.label, tone: 'idle' };
}
export const progress = pct => Number.isInteger(pct) && pct >= 0 && pct <= 100
  ? { known: true, text: pct + "%", style: "--pct:" + pct + "%;--ph:" + Math.round(42 + pct * 1.03) }
  : { known: false, text: "—", style: "" };
const LABELS = f({ claude: "Claude", codex: "Codex", deepseek: "DeepSeek", kimi: "Kimi" });
export const modelLabel = a => a && typeof a.name === "string" ? a.name
  : a && typeof a.model === "string" && Object.hasOwn(LABELS, a.model) ? LABELS[a.model] : null;
