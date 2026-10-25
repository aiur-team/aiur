defmodule Aiur.Orchestrator.IssueSync.DecisionStoreOutage do
  @moduledoc """
  Keeps decision-store outage alerts separate from capacity holds.
  """

  alias Aiur.AlertFeed
  alias Aiur.Alerts
  alias Aiur.Orchestrator.IssueSync.CapacityConstraints
  alias Aiur.Orchestrator.State

  @spec sync_decision_store_unavailable_alert(State.t(), list()) :: State.t()
  def sync_decision_store_unavailable_alert(%State{} = state, issues) when is_list(issues),
    do: sync_decision_store_unavailable_alert(state, issues, System.monotonic_time(:millisecond))

  def sync_decision_store_unavailable_alert(%State{} = state, _issues), do: state

  @doc false
  @spec sync_decision_store_unavailable_alert(State.t(), list(), integer()) :: State.t()
  def sync_decision_store_unavailable_alert(%State{} = state, issues, now_ms)
      when is_list(issues) and is_integer(now_ms) do
    if decision_store_unavailable_with_ready_work?(state, issues) do
      hold_decision_store_unavailable_alert(state, now_ms)
    else
      clear_decision_store_unavailable_alert(state)
    end
  end

  def sync_decision_store_unavailable_alert(%State{} = state, _issues, _now_ms), do: state

  # A DecisionStore outage is surfaced as its own needs-attention alert rather
  # than as capacity starvation: `blocked_on_decision?/2` fails closed on
  # `:unavailable`, so every queued ticket reads as decision-blocked, the ready
  # set empties, and the capacity-starvation alerts would otherwise stay silent
  # for the duration of the outage (#2453). The "ready" set is computed WITHOUT
  # the open-Command gate so queued dispatchable work is still visible here
  # while `blocked_ticket_ids` is `:unavailable`.
  defp decision_store_unavailable_with_ready_work?(%State{} = state, issues) do
    state.blocked_ticket_ids == :unavailable and
      CapacityConstraints.ready_dispatch_issues_without_decision_gate(state, issues) != []
  end

  defp hold_decision_store_unavailable_alert(%State{} = state, now_ms) do
    since_ms = state.decision_store_unavailable_since_ms || now_ms
    state = %{state | decision_store_unavailable_since_ms: since_ms}

    if state.decision_store_unavailable_alert_active or
         now_ms - since_ms < CapacityConstraints.capacity_starvation_dwell_ms() do
      state
    else
      emit_decision_store_unavailable_alert(state)
    end
  end

  defp emit_decision_store_unavailable_alert(%State{} = state) do
    case Alerts.emit_system("system.dispatch.decision_store_unavailable",
           reason:
             "The DecisionStore could not be read; dispatch is admitting nothing and capacity-starvation " <>
               "alerting is suppressed while this holds. Recovery restores dispatch and normal capacity alerting.",
           needs_attention: true,
           severity: "warning"
         ) do
      :ok ->
        %{
          state
          | decision_store_unavailable_alert_active: true,
            decision_store_unavailable_alert_resolution_emitted: false
        }

      {:error, _reason} ->
        state
    end
  end

  defp clear_decision_store_unavailable_alert(%State{decision_store_unavailable_alert_resolution_emitted: true} = state) do
    %{
      state
      | decision_store_unavailable_since_ms: nil,
        decision_store_unavailable_alert_active: false
    }
  end

  defp clear_decision_store_unavailable_alert(%State{} = state) do
    active? =
      state.decision_store_unavailable_alert_active or
        AlertFeed.active_system_attention?("system.dispatch.decision_store_unavailable")

    if active? do
      case Alerts.emit_system("system.dispatch.decision_store_unavailable.resolved",
             reason: "The DecisionStore is reachable again; dispatch and normal capacity alerting have resumed.",
             needs_attention: false,
             severity: "info"
           ) do
        :ok ->
          %{
            state
            | decision_store_unavailable_since_ms: nil,
              decision_store_unavailable_alert_active: false,
              decision_store_unavailable_alert_resolution_emitted: true
          }

        {:error, _reason} ->
          state
      end
    else
      %{
        state
        | decision_store_unavailable_since_ms: nil,
          decision_store_unavailable_alert_active: false,
          decision_store_unavailable_alert_resolution_emitted: true
      }
    end
  end
end
