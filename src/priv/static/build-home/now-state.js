const f = Object.freeze;
export const AST = f({
  active: f({ label: "Running", cls: "active" }), error: f({ label: "Error", cls: "stuck" }), retries: f({ label: "Retries exhausted", cls: "stuck" }),
  command: f({ label: "Awaiting command", cls: "stuck" }), paused: f({ label: "Paused", cls: "idle" }), parked: f({ label: "Parked", cls: "idle" }),
});
export const UNKNOWN_STATE = f({ label: "State unknown", cls: null });
export const agentState = s => typeof s === "string" && Object.hasOwn(AST, s) ? AST[s] : UNKNOWN_STATE;
export const progress = pct => Number.isInteger(pct) && pct >= 0 && pct <= 100
  ? { known: true, text: pct + "%", style: "--pct:" + pct + "%;--ph:" + Math.round(42 + pct * 1.03) }
  : { known: false, text: "—", style: "" };
const LABELS = f({ claude: "Claude", codex: "Codex", deepseek: "DeepSeek", kimi: "Kimi" });
export const modelLabel = a => a && typeof a.name === "string" ? a.name
  : a && typeof a.model === "string" && Object.hasOwn(LABELS, a.model) ? LABELS[a.model] : null;
