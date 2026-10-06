defmodule Aiur.BuildOrder.GraphProjection.ReconciliationTimer do
  @moduledoc false

  # Independent of catalog rebuilds and viewers: a healthy stream does not
  # prove that sub-issue deliveries are configured or that none were lost.
  @spec arm(map()) :: map()
  def arm(state) do
    state = cancel(state)
    token = make_ref()
    delay = state.policy.reconciliation_cooldown_ms
    timer_ref = Process.send_after(self(), {:reconcile_membership, token}, delay)
    %{state | reconciliation_timer: %{token: token, timer_ref: timer_ref}}
  end

  @spec cancel(map()) :: map()
  def cancel(%{reconciliation_timer: %{timer_ref: ref}} = state) do
    Process.cancel_timer(ref)
    %{state | reconciliation_timer: nil}
  end

  def cancel(state), do: state
end
