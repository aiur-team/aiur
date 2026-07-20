defmodule AiurWeb.OperatorControlCenter.RunSummaryStrip do
  @moduledoc """
  The compact three-card run/usage strip at the top of the Units page: a run
  Summary card plus one card per active agent vendor (Codex, Claude) showing
  tokens, spend, and session/weekly rate-limit meters.

  Ported from the Claude design (`.run-summary` / `.rs-*`). The values are
  STUBBED for now — see the `assigns` defaults — pending a real usage-summary
  source. Vendor logos and token icons live in `priv/static`.
  """

  use Phoenix.Component

  @spec run_summary_strip(map()) :: Phoenix.LiveView.Rendered.t()
  def run_summary_strip(assigns) do
    ~H"""
    <section class="run-summary" aria-label="Run summary and vendor usage">
      <div class="rs-block rs-status">
        <div class="rs-head">
          <img class="rs-logo" src="/aiur-logo.png" alt="" aria-hidden="true" />
          <span class="rs-name">Summary</span>
        </div>
        <div class="rs-status-rows">
          <div class="rs-stat">
            <span class="rs-stat-label">Live</span>
            <span class="rs-stat-val">10 units</span>
          </div>
          <div class="rs-stat">
            <span class="rs-stat-label">Tickets</span>
            <span class="rs-stat-val">20 remain</span>
          </div>
          <div class="rs-stat">
            <span class="rs-stat-label">Spend</span>
            <span class="rs-stat-val rs-stat-spend">$50.47</span>
          </div>
        </div>
        <div class="rs-progress">
          <div class="rs-limit-top">
            <span class="rs-limit-label">Progress</span>
            <span class="rs-limit-meta">1h 47m elapsed</span>
            <span class="rs-limit-meta">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></svg>
              ETA 58 min
            </span>
          </div>
          <div class="rs-meter"><i style="width:65%"></i></div>
        </div>
      </div>

      <.vendor_card
        logo="/codex-color.svg"
        token_ic="/codex-token.svg"
        name="Codex"
        tokens="0.89M"
        spend="$12.07"
        session_pct={19}
        session_meta="19% · resets in 40m"
        weekly_pct={31}
        weekly_meta="31% · resets Mon 9:00 AM"
      />

      <.vendor_card
        logo="/claude-symbol.svg"
        token_ic="/claude-token.svg"
        name="Claude"
        tokens="1.24M"
        spend="$38.40"
        session_pct={28}
        session_meta="28% · resets in 22m"
        weekly_pct={47}
        weekly_meta="47% · resets Thu 6:00 PM"
      />
    </section>
    """
  end

  attr(:logo, :string, required: true)
  attr(:token_ic, :string, required: true)
  attr(:name, :string, required: true)
  attr(:tokens, :string, required: true)
  attr(:spend, :string, required: true)
  attr(:session_pct, :integer, required: true)
  attr(:session_meta, :string, required: true)
  attr(:weekly_pct, :integer, required: true)
  attr(:weekly_meta, :string, required: true)

  defp vendor_card(assigns) do
    ~H"""
    <div class="rs-block">
      <div class="rs-head">
        <img class="rs-logo" src={@logo} alt="" aria-hidden="true" />
        <span class="rs-name">{@name}</span>
        <div class="rs-head-stats">
          <div class="rs-stat">
            <span class="rs-stat-label">Tokens</span>
            <span class="rs-stat-val">{@tokens}<img class="rs-token-ic" src={@token_ic} alt="tokens" /></span>
          </div>
          <div class="rs-stat">
            <span class="rs-stat-label">Spend</span>
            <span class="rs-stat-val rs-stat-spend">{@spend}</span>
          </div>
        </div>
      </div>
      <div class="rs-limits">
        <div class="rs-limit">
          <div class="rs-limit-top"><span class="rs-limit-label">Session</span><span class="rs-limit-meta">{@session_meta}</span></div>
          <div class="rs-meter"><i style={"width:#{@session_pct}%"}></i></div>
        </div>
        <div class="rs-limit">
          <div class="rs-limit-top"><span class="rs-limit-label">Weekly</span><span class="rs-limit-meta">{@weekly_meta}</span></div>
          <div class="rs-meter"><i style={"width:#{@weekly_pct}%"}></i></div>
        </div>
      </div>
    </div>
    """
  end
end
