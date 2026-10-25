defmodule Aiur.Orchestrator.Dispatcher.BudgetTrip do
  # Cohesion: persist and report dispatch and lifetime-latch breaker outcomes.
  @moduledoc """
  Thrash breaker trip and durable lifetime-latch persistence.
  """

  require Logger

  alias Aiur.Alerts
  alias Aiur.{CodeHost, Config, Issue, Tracker}
  alias Aiur.GitHub.{Issues, StatePolicy}
  alias Aiur.Orchestrator.Dispatcher.Budgets
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Orchestrator.TrackerTasks

  @doc false
  @spec trip_thrash_breaker(State.t(), term()) :: State.t()
  def trip_thrash_breaker(%State{} = state, issue) do
    state = persist_lifetime_trip(state, issue, &write_lifetime_latch_state(issue, &1, &2))
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

  defp write_lifetime_latch_state(issue, identifier, target) do
    result =
      if Tracker.adapter() == Aiur.GitHub.Tracker do
        prefix = Aiur.GitHub.Config.label_prefix()

        with :ok <- TicketTransition.write_marker(identifier, :add, "needs-triage", writer: :dispatcher),
             :ok <- TicketTransition.write_state(identifier, target, writer: :dispatcher, expected_state: issue.state) do
          TicketTransition.write_marker(identifier, :remove, StatePolicy.state_label(prefix, target), writer: :dispatcher)
        end
      else
        TicketTransition.write_state(identifier, target, writer: :dispatcher, expected_state: issue.state)
      end

    case result do
      {:error, {:stale_issue_state, _expected, _actual}} = error ->
        confirm_lifetime_latch_state(error, identifier, target)

      result ->
        result
    end
  end

  defp confirm_lifetime_latch_state(error, identifier, target) do
    if Tracker.adapter() == Aiur.GitHub.Tracker do
      confirm_github_lifetime_latch(error, identifier)
    else
      confirm_other_lifetime_latch(error, identifier, target)
    end
  end

  defp confirm_other_lifetime_latch(error, identifier, target) do
    case Tracker.fetch_issue_states_by_ids([identifier]) do
      {:ok, [%Issue{state: current_state}]} ->
        if DispatchPolicy.state_slug(current_state) == DispatchPolicy.state_slug(target), do: :ok, else: error

      _other ->
        error
    end
  end

  defp confirm_github_lifetime_latch(error, identifier) do
    with {:ok, body, _source} <- Issues.fetch_issue_raw_conditional(identifier, revalidate: true, caller: "lifetime_latch_verify"),
         labels when is_list(labels) <- Map.get(body, "labels"),
         label_names <- Enum.map(labels, &Map.get(&1, "name", "")),
         true <- "needs-triage" in label_names,
         true <- Issues.extract_state_labels(label_names, Aiur.GitHub.Config.label_prefix()) == [] do
      :ok
    else
      _other -> error
    end
  end

  @doc false
  # The lifetime dispatch latch counts repeated work attempts, not transport
  # faults. Park it for triage instead of presenting it as agent:error.
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
        fn -> apply_lifetime_latch(issue, entry, update_state_fun) end,
        fn current, result ->
          apply_current_lifetime_trip(current, issue, entry, result)
        end
      )
    else
      state
    end
  end

  defp apply_lifetime_latch(issue, entry, update_state_fun) do
    lifetime = Map.get(entry, :lifetime, 0)
    maximum = Config.agent_max_dispatches_per_ticket()
    tracker = Tracker.adapter()

    with :ok <- update_state_fun.(issue.identifier, "needs-triage"),
         {:ok, pull_requests} <- open_pull_requests(issue.identifier),
         :ok <- write_lifetime_comment(issue.identifier, lifetime, maximum, Map.get(entry, :window_start_ms), pull_requests, tracker) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_pull_requests(identifier) do
    if Tracker.adapter() == Aiur.GitHub.Tracker do
      CodeHost.fetch_open_pull_requests_for_branch(identifier)
    else
      {:ok, []}
    end
  end

  defp write_lifetime_comment(identifier, lifetime, maximum, latch_generation, pull_requests, tracker) do
    marker = "<!-- aiur-lifetime-latch:#{identifier}:#{lifetime}:#{latch_generation} -->"

    case tracker.fetch_classified_issue_comments(identifier) do
      {:ok, comments} when is_list(comments) ->
        if Enum.any?(comments, &String.contains?(Map.get(&1, "body", ""), marker)) do
          :ok
        else
          TicketTransition.write_comment(identifier, lifetime_comment(lifetime, maximum, pull_requests) <> "\n\n" <> marker, writer: :dispatcher, tracker: tracker)
        end

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_issue_comments, other}}
    end
  end

  defp lifetime_comment(lifetime, maximum, pull_requests) do
    prs =
      case Enum.map(pull_requests, &pull_request_reference/1) |> Enum.reject(&is_nil/1) do
        [] -> "No open pull requests were found."
        references -> "Open pull request(s): " <> Enum.join(references, ", ") <> "."
      end

    "Automatically parked as `needs-triage` after #{lifetime}/#{maximum} lifetime dispatches. #{prs}"
  end

  defp pull_request_reference(%{"number" => number, "html_url" => url}) when is_integer(number) and is_binary(url),
    do: "##{number} (#{url})"

  defp pull_request_reference(%{:number => number, :html_url => url}) when is_integer(number) and is_binary(url),
    do: "##{number} (#{url})"

  defp pull_request_reference(_pull_request), do: nil

  defp apply_current_lifetime_trip(current, issue, expected, result) do
    latest = Map.get(Budgets.thrash_budget(current), issue.id, %{})

    if Map.take(latest, [:tripped, :lifetime, :window_start_ms]) == Map.take(expected, [:tripped, :lifetime, :window_start_ms]) do
      apply_lifetime_trip_result(current, issue, latest, result)
    else
      current
    end
  end

  defp apply_lifetime_trip_result(current, issue, latest, :ok), do: apply_lifetime_latch_park_write(current, issue, latest)

  defp apply_lifetime_trip_result(current, issue, latest, {:error, reason}), do: handle_lifetime_latch_write_failure(current, issue, latest, reason)

  defp apply_lifetime_latch_park_write(%State{} = state, %Issue{} = issue, entry) do
    lifetime = Map.get(entry, :lifetime, 0)
    maximum = Config.agent_max_dispatches_per_ticket()

    Alerts.emit_custom(
      "ticket.#{issue.identifier}.agent.attention.error-lifetime_latch",
      "Ticket was automatically parked as needs-triage after #{lifetime}/#{maximum} lifetime dispatches.",
      issue: issue.identifier,
      reason: "Ticket was automatically parked as needs-triage after #{lifetime}/#{maximum} lifetime dispatches; no Executor action is needed.",
      needs_attention: false,
      severity: "info",
      # Keep the once-per-latch informational event in the central feed.
      central: true
    )

    updated_entry = Map.put(entry, :durable_latch_applied, true)
    state = Budgets.put_thrash_budget(state, Map.put(Budgets.thrash_budget(state), issue.id, updated_entry))

    %{
      state
      | claimed: MapSet.delete(state.claimed, issue.id),
        observed_error_alerts: MapSet.delete(state.observed_error_alerts, issue.id),
        observed_error_alert_causes: Map.delete(state.observed_error_alert_causes, issue.id)
    }
  end

  defp handle_lifetime_latch_write_failure(%State{} = state, %Issue{} = issue, entry, reason) do
    Logger.error("Unable to persist lifetime dispatch latch: issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")

    # The automatic triage park did not fully land, so leave the latch
    # retryable and alert once rather than hiding a stranded ticket.
    if entry[:latch_alert_emitted] do
      state
    else
      Alerts.emit_custom(
        "ticket.#{issue.identifier}.agent.attention.lifetime_latch_write_failed",
        "Lifetime dispatch latch could not park ticket in needs-triage (#{inspect(reason)}); it remains active for retry.",
        issue: issue.identifier,
        reason: "The lifetime-latch triage park failed (#{inspect(reason)}); the ticket remains active and may be re-dispatched.",
        needs_attention: true,
        severity: "warning",
        central: true
      )

      Budgets.put_thrash_budget(state, Map.put(Budgets.thrash_budget(state), issue.id, Map.put(entry, :latch_alert_emitted, true)))
    end
  end
end
