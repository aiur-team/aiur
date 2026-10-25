const f = Object.freeze;
export const AST = f({
  active: f({ label: "Running", cls: "active" }), error: f({ label: "Error", cls: "stuck" }), retries: f({ label: "Retries exhausted", cls: "stuck" }),
  retrying: f({ label: "Retrying", cls: "queued" }), command: f({ label: "Awaiting command", cls: "stuck" }), paused: f({ label: "Paused", cls: "idle" }), parked: f({ label: "Parked", cls: "idle" }),
  "merge-queued": f({ label: "agent:merge-queued", cls: "queued" }), "ci-red": f({ label: "agent:ci-red", cls: "stuck" }),
  "body-fix": f({ label: "agent:body-fix", cls: "stuck" }), "paused-usage-limit": f({ label: "agent:paused-usage-limit", cls: "idle" }),
  "paused-decision": f({ label: "agent:paused-decision", cls: "idle" }), "paused-agent": f({ label: "agent:paused-agent", cls: "idle" }),
  blocked: f({ label: "agent:blocked", cls: "queued" }), "handed-off": f({ label: "agent:handed-off", cls: "idle" }),
  usage_limited: f({ label: "Paused · usage limit", cls: "idle" }), ci_wait: f({ label: "Waiting for CI", cls: "idle" }),
});
export const UNKNOWN_STATE = f({ label: "State unknown", cls: null });
export const agentState = s => typeof s === "string" && Object.hasOwn(AST, s) ? AST[s] : UNKNOWN_STATE;
export const progress = pct => Number.isInteger(pct) && pct >= 0 && pct <= 100
  ? { known: true, text: pct + "%", style: "--pct:" + pct + "%;--ph:" + Math.round(42 + pct * 1.03) }
  : { known: false, text: "—", style: "" };
const LABELS = f({ claude: "Claude", codex: "Codex", deepseek: "DeepSeek", kimi: "Kimi" });
export const modelLabel = a => a && typeof a.name === "string" ? a.name
  : a && typeof a.model === "string" && Object.hasOwn(LABELS, a.model) ? LABELS[a.model] : null;
