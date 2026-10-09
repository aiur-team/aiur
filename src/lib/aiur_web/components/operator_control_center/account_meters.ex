defmodule AiurWeb.OperatorControlCenter.AccountMeters do
  @moduledoc "Named per-account weekly bars on the home summary."
  use Phoenix.Component
  import AiurWeb.OperatorControlCenter.MeterStyles, only: [meter_class: 3]

  attr(:accounts, :list, required: true)
  @spec rows(map()) :: Phoenix.LiveView.Rendered.t()
  def rows(assigns) do
    ~H"""
          <div :for={account <- @accounts} class="rs-limit" data-account={account.name}>
            <span class="rs-limit-label">{account.name}</span>
            <div class="rs-meter" role="progressbar" aria-label={"#{account.name} weekly usage"} aria-valuenow={account.percent} aria-valuemin="0" aria-valuemax="100">
              <i :if={is_number(account.percent)} class={meter_class(account.percent, 80, 90)} style={"width:#{min(max(account.percent, 0), 100)}%"}></i>
            </div>
            <span class="rs-limit-meta">{if is_number(account.percent), do: "#{account.percent}%", else: "unknown"} · {account.freshness}<span :if={is_integer(account.age_seconds)}> · {account.age_seconds}s old</span></span>
          </div>
    """
  end
end
