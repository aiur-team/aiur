defmodule Aiur.DecisionDispatchTasks.Saturation do
  @moduledoc false

  require Logger

  alias Aiur.Alerts

  @type state :: map()

  @spec mark(state()) :: state()
  def mark(%{saturated?: true} = state), do: state

  def mark(state) do
    notify_safely(state.saturation_notifier, :saturated)
    %{state | saturated?: true}
  end

  @spec maybe_resolve(state()) :: state()
  def maybe_resolve(%{saturated?: false} = state), do: state

  def maybe_resolve(state) do
    if recovered?(state) do
      notify_safely(state.saturation_notifier, :recovered)
      %{state | saturated?: false}
    else
      state
    end
  end

  @spec notify(:saturated | :recovered) :: term()
  def notify(:saturated) do
    Logger.warning("decision dispatch queue saturated")

    Alerts.emit_custom(
      "system.decision_dispatch.saturated",
      "Decision dispatch is saturated; newly answered Decisions are failing durably for explicit retry.",
      needs_attention: true,
      severity: "warning",
      central: true
    )
  end

  def notify(:recovered) do
    Logger.info("decision dispatch queue recovered")

    Alerts.emit_custom(
      "system.decision_dispatch.saturated.resolved",
      "Decision dispatch capacity recovered.",
      needs_attention: false,
      severity: "info",
      central: true
    )
  end

  defp recovered?(state) do
    state.pending < state.max_pending and
      Enum.all?(state.queues, fn {_ticket, queue} ->
        :queue.len(queue) < state.max_pending_per_ticket
      end)
  end

  defp notify_safely(notifier, transition) do
    notifier.(transition)
    :ok
  rescue
    error ->
      Logger.error("decision dispatch saturation notification failed error=#{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.error("decision dispatch saturation notification failed kind=#{kind} reason=#{inspect(reason)}")
      :ok
  end
end
