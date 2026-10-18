defmodule Aiur.LandingWatch.RecoveryRuntime do
  @moduledoc false

  @doc false
  @spec retry_or_drain(map()) :: map()
  def retry_or_drain(%{active_recovery_window: window, active_recovery_attempt: 0} = state) when not is_nil(window) do
    Process.send_after(self(), {:poll_recovery, window, 1}, state.interval_ms)
    %{state | active_recovery_window: nil, active_recovery_attempt: 0}
  end

  def retry_or_drain(%{active_recovery_window: window} = state) when not is_nil(window),
    do: drain_pending(%{state | active_recovery_window: nil, active_recovery_attempt: 0})

  def retry_or_drain(state), do: drain_pending(state)

  @spec message({{integer(), integer()}, non_neg_integer()}) :: {:poll_recovery, {integer(), integer()}, non_neg_integer()}
  def message({window, attempt}), do: {:poll_recovery, window, attempt}

  defp drain_pending(%{pending_recovery_window: pending} = state) when not is_nil(pending) do
    send(self(), message(pending))
    %{state | pending_recovery_window: nil}
  end

  defp drain_pending(state), do: state
end
