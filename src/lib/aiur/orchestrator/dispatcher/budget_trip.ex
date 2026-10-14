defmodule Aiur.Orchestrator.Dispatcher.BudgetTrip do
  @moduledoc """
  Thrash breaker trip and durable lifetime-latch persistence.
  """

  require Logger

  alias Aiur.Alerts
  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.Orchestrator.Dispatcher.Budgets
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Orchestrator.TrackerTasks

  @doc false
  @spec trip_thrash_breaker(State.t(), term()) :: State.t()
  def trip_thrash_breaker(%State{} = state, issue) do
    state = persist_lifetime_trip(state, issue, fn identifier, target -> TicketTransition.write_state(identifier, target, writer: :dispatcher, expected_state: issue.state) end)
    entry = Map.get(Budgets.thrash_budget(state), issue.id, %{})

    if Map.get(entry, :alert_emitted, false) do
      state
    else
      count = Map.get(entry, :count, 0)
      lifetime = Map.get(entry, :lifetime, 0)
      reason = Map.get(entry, :tripped, :window)
      lifetime_max = Config.agent_max_dispatches_per_ticket()

      Logger.warning(
        "Codex thrash detected: issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{reason} restarts=#{count} lifetime=#{lifetime} lifetime_max=#{lifetime_max} window_seconds=#{Config.codex_thrash_window_seconds()}; skipping dispatch"
      )

      alert_body =
        if reason == :lifetime do
          "Ticket is latched by the lifetime dispatch budget (#{lifetime}/#{lifetime_max}). This is terminal, not a transient circuit: `resume` cannot clear it. Run `aiurdev reset-budget #{issue.identifier}` to restore dispatchability (or move the ticket through a documented reset path)."
        else
          "Codex dispatch circuit opened (#{reason}); window restarts=#{count}, lifetime dispatches=#{lifetime}/#{lifetime_max}."
        end

      Alerts.emit_system("ticket.#{issue.identifier}.agent.thrash_circuit_open",
        issue: issue.identifier,
        reason: alert_body,
        needs_attention: true,
        severity: "warning"
      )

      updated_entry = Map.put(entry, :alert_emitted, true)
      Budgets.put_thrash_budget(state, Map.put(Budgets.thrash_budget(state), issue.id, updated_entry))
    end
  end

  @doc false
  # The lifetime dispatch latch is deliberately terminal and deliberately does
  # not route through `Errors.retryable_github_error?/1` (#2427). It is a
  # count, not a transport fault: it trips after `agent_max_dispatches_per_ticket`
  # sessions that survived provisioning and started real work (#1453), so there
  # is no error reason to classify at this site, and the auto-resume path
  # refuses latched tickets by design — `agent:error` is the Executor-visible
  # state that signals "this ticket needs `aiurdev reset-budget` or a
  # documented reset path". The #2427 fix closes the *single-fault* route
  # (a transport failure no longer exhausts into `agent:error` or releases a
  # claim with no re-claim); a *sustained* outage that re-dispatches a ticket
  # until it exhausts the lifetime budget remains a structural-stuck breaker,
  # out of scope for the error-classification split this ticket is about.
  @spec persist_lifetime_trip(State.t(), Issue.t(), (String.t(), String.t() -> :ok | {:error, term()})) ::
          State.t()
  def persist_lifetime_trip(%State{} = state, %Issue{} = issue, update_state_fun)
      when is_function(update_state_fun, 2) do
    entry = Map.get(Budgets.thrash_budget(state), issue.id, %{})

    if entry[:tripped] == :lifetime and entry[:durable_latch_applied] != true and
         is_binary(issue.identifier) do
      TrackerTasks.run(
        state,
        {:lifetime_latch, issue.id},
        fn ->
          update_state_fun.(issue.identifier, "error")
        end,
        fn current, result ->
          apply_current_lifetime_trip(current, issue, entry, result)
        end
      )
    else
      state
    end
  end

  defp apply_current_lifetime_trip(current, issue, expected, result) do
    latest = Map.get(Budgets.thrash_budget(current), issue.id, %{})

    if Map.take(latest, [:tripped, :lifetime, :window_start_ms]) == Map.take(expected, [:tripped, :lifetime, :window_start_ms]) do
      apply_lifetime_trip_result(current, issue, latest, result)
    else
      current
    end
  end

  defp apply_lifetime_trip_result(current, issue, latest, :ok), do: apply_lifetime_latch_error_write(current, issue, latest)

  defp apply_lifetime_trip_result(current, issue, latest, {:error, reason}), do: handle_lifetime_latch_write_failure(current, issue, latest, reason)

  defp apply_lifetime_latch_error_write(%State{} = state, %Issue{} = issue, entry) do
    lifetime = Map.get(entry, :lifetime, 0)
    maximum = Config.agent_max_dispatches_per_ticket()

    Alerts.emit_custom(
      "ticket.#{issue.identifier}.agent.attention.error-lifetime_latch",
      "Agent entered error because its lifetime dispatch latch is #{lifetime}/#{maximum}; this will not clear on its own.",
      issue: issue.identifier,
      reason: "Agent entered error because its lifetime dispatch latch is #{lifetime}/#{maximum}; this will not clear on its own.",
      needs_attention: true,
      severity: "warning",
      # IssueSync reconstructs the persisted error cause after a restart
      # from the central feed only, so this attention must land there or
      # it can never be resolved or rearmed.
      central: true
    )

    updated_entry = Map.put(entry, :durable_latch_applied, true)
    state = Budgets.put_thrash_budget(state, Map.put(Budgets.thrash_budget(state), issue.id, updated_entry))

    %{
      state
      | claimed: MapSet.delete(state.claimed, issue.id),
        observed_error_alerts: MapSet.put(state.observed_error_alerts, issue.id),
        observed_error_alert_causes: Map.put(state.observed_error_alert_causes, issue.id, :lifetime_latch)
    }
  end

  defp handle_lifetime_latch_write_failure(%State{} = state, %Issue{} = issue, entry, reason) do
    Logger.error("Unable to persist lifetime dispatch latch: issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")

    # The terminal `error` write that would park the ticket never landed,
    # so it keeps its active-state label; alert (once) rather than only
    # logging so the Executor sees a stranded ticket (#2420).
    if entry[:latch_alert_emitted] do
      state
    else
      Alerts.emit_custom(
        "ticket.#{issue.identifier}.agent.attention.lifetime_latch_write_failed",
        "Lifetime dispatch latch could not be persisted as error (#{inspect(reason)}); the ticket keeps its active-state label.",
        issue: issue.identifier,
        reason: "The lifetime-latch error-state write failed (#{inspect(reason)}); the ticket was not parked in error and may be re-dispatched.",
        needs_attention: true,
        severity: "warning",
        central: true
      )

      Budgets.put_thrash_budget(state, Map.put(Budgets.thrash_budget(state), issue.id, Map.put(entry, :latch_alert_emitted, true)))
    end
  end
end
