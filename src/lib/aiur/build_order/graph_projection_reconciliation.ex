defmodule Aiur.BuildOrder.GraphProjection.Reconciliation do
  @moduledoc false

  # The rare GitHub re-converge task: start, cancel and the degraded-delivery cooldown.
  # Runs inside the projection process: every `self()` here is the GenServer.

  require Logger

  alias Aiur.BuildOrder.GraphProjection.{Reads, Schedule}
  alias Aiur.Webhooks

  # The rare reconciliation: re-fetch the Build Order graph from GitHub and
  # write it back into the store, whose change events then rebuild the
  # projection. Boot, explicit refresh, degradation and the bounded membership
  # timer cover lost deliveries without depending on viewers or webhook health.
  @spec start_reconciliation(map()) :: map()
  def start_reconciliation(state) do
    if is_nil(state.reconciliation) do
      reader_options = Reads.reader_options(state, false)
      reconciliation_fun = state.reconciliation_fun

      task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn ->
          reconciliation_fun.(reader_options)
        end)

      %{state | reconciliation: %{ref: task.ref, pid: task.pid}, last_reconciliation_ms: Schedule.now_ms(state)}
    else
      state
    end
  rescue
    _error ->
      # A reconciliation that cannot even start must never take the projection
      # down: the event-sourced catalog remains on whatever the store holds.
      Logger.warning("GraphProjection could not start reconciliation")
      state
  catch
    :exit, _reason ->
      Logger.warning("GraphProjection reconciliation task exited at start")
      state
  end

  @spec cancel_reconciliation(map()) :: map()
  def cancel_reconciliation(state) do
    case state.reconciliation do
      %{ref: ref, pid: pid} ->
        Process.demonitor(ref, [:flush])
        Task.Supervisor.terminate_child(state.task_supervisor, pid)
        %{state | reconciliation: nil}

      nil ->
        state
    end
  end

  # While a repo's delivery mode is degraded, deliveries are being dropped, so
  # the event-sourced store cannot be trusted to converge on its own — this is
  # the ticket's dropped-delivery path. The reconciliation re-fetches from
  # GitHub; gated by a cooldown (default the silence threshold) so a degraded
  # repo does not re-converge on every store event.
  @spec maybe_reconcile_degraded(map()) :: map()
  def maybe_reconcile_degraded(state) do
    if degraded?(state) and is_nil(state.reconciliation) and reconciliation_due?(state) do
      start_reconciliation(state)
    else
      state
    end
  end

  defp degraded?(state) do
    case state.active_repository do
      {owner, repo} ->
        "#{owner}/#{repo}"
        |> Webhooks.mode()
        |> then(&(&1.state == :degraded))

      _other ->
        false
    end
  end

  @spec reconciliation_due?(map()) :: boolean()
  def reconciliation_due?(state) do
    case state.last_reconciliation_ms do
      nil -> true
      last -> Schedule.now_ms(state) - last >= state.policy.reconciliation_cooldown_ms
    end
  end
end
