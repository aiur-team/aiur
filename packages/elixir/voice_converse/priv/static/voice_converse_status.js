export function renderSessionInfo(view, frame) {
  const values = {
    option: frame.label,
    cost: frame.cost_estimate_usd === undefined ? null : `Estimated cost: $${Number(frame.cost_estimate_usd).toFixed(2)}`,
    session: frame.session_seconds_left === undefined ? null : `${Math.ceil(frame.session_seconds_left / 60)} min session time left`,
    daily: frame.minutes_left_today === undefined ? null : `${frame.minutes_left_today} min left today`,
    replay: frame.fork_mode === "replay" ? "Answer uses a saved summary" : null,
  };
  for (const [field, value] of Object.entries(values)) {
    const element = view?.querySelector(`[data-session-info="${field}"]`);
    if (!element) continue;
    element.textContent = value || "";
    element.hidden = !value;
  }
}
