defmodule Aiur.Orchestrator.StartupClaimReconciler do
  @moduledoc """
  Releases tracker claims whose runtime did not survive orchestrator startup.

  The first successful candidate poll is the first point where tracker state
  and the current runtime registry can be compared safely. A failed release
  leaves this pass incomplete so a later successful poll retries it.
  """

  require Logger

  alias Aiur.{Alerts, Config, Issue, Tracker}
  alias Aiur.Orchestrator.{DispatchPolicy, State}

  @spec reconcile(State.t(), [Issue.t()], keyword()) :: {State.t(), [Issue.t()]}
  def reconcile(state, issues, opts \\ [])

  def reconcile(%State{startup_claim_reconciliation_complete?: true} = state, issues, _opts)
      when is_list(issues) do
    {state, issues}
  end

  def reconcile(%State{} = state, issues, opts) when is_list(issues) and is_list(opts) do
    live_identifiers = live_runtime_identifiers(state.running)

    {issues, {state, complete?}} =
      Enum.map_reduce(issues, {state, true}, fn issue, {state_acc, complete?} ->
        case reconcile_issue(state_acc, issue, live_identifiers, opts) do
          {:ok, state_acc, issue} -> {issue, {state_acc, complete?}}
          {:error, state_acc, issue} -> {issue, {state_acc, false}}
        end
      end)

    {%{state | startup_claim_reconciliation_complete?: complete?}, issues}
  end

  defp reconcile_issue(%State{} = state, %Issue{identifier: identifier} = issue, live_identifiers, opts)
       when is_binary(identifier) do
    cond do
      DispatchPolicy.state_slug(issue.state) != "in-progress" ->
        {:ok, resolve_release_failure(state, issue, opts), issue}

      MapSet.member?(live_identifiers, identifier) ->
        {:ok, resolve_release_failure(state, issue, opts), issue}

      true ->
        release_orphaned_claim(state, issue, opts)
    end
  end

  defp reconcile_issue(state, issue, _live_identifiers, _opts), do: {:ok, state, issue}

  defp live_runtime_identifiers(running) do
    Enum.reduce(running, MapSet.new(), fn
      {_issue_id, %{identifier: identifier, pid: pid}}, identifiers when is_binary(identifier) ->
        if State.alive?(pid), do: MapSet.put(identifiers, identifier), else: identifiers

      _entry, identifiers ->
        identifiers
    end)
  end

  defp release_orphaned_claim(%State{} = state, %Issue{} = issue, opts) do
    todo_state = lifecycle_state_name(opts, "todo", "todo")

    update_issue_state_fun =
      Keyword.get(opts, :update_issue_state_fun, fn identifier, state_name, expected_state ->
        Tracker.update_issue_state(identifier, state_name, expected_state: expected_state)
      end)

    case update_issue_state_fun.(issue.identifier, todo_state, issue.state) do
      :ok ->
        Logger.warning("Released orphaned startup claim to todo; no live runtime owns it #{State.issue_context(issue)}")

        emit_released_alert(issue, opts)
        state = resolve_release_failure(state, issue, opts)
        {:ok, state, %{issue | state: todo_state}}

      {:error, reason} ->
        state = emit_release_failed(state, issue, reason, opts)
        {:error, state, issue}

      unexpected ->
        state = emit_release_failed(state, issue, {:unexpected_result, unexpected}, opts)
        {:error, state, issue}
    end
  end

  defp emit_released_alert(%Issue{} = issue, opts) do
    emit_alert_fun = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

    emit_alert_fun.(
      "ticket.#{issue.identifier}.agent.startup_orphan_claim_released",
      issue: issue,
      message: "Startup reconciliation released ticket #{issue.identifier} from in-progress to todo.",
      reason: "Ticket #{issue.identifier} carried an in-progress claim but no live runtime in the current orchestrator registry owned it, so the claim was released by compare-and-set.",
      needs_attention: false,
      severity: "warning"
    )
  end

  defp emit_release_failed(%State{} = state, %Issue{} = issue, reason, opts) do
    signature = {issue.identifier, inspect(reason)}
    prior_failure? = failure_recorded?(state, issue)

    unless prior_failure? do
      Logger.error("Failed to release orphaned startup claim: #{inspect(reason)}; retrying on a later candidate poll #{State.issue_context(issue)}")

      emit_alert_fun = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

      emit_alert_fun.(
        failure_topic(issue),
        issue: issue,
        message: "Startup reconciliation could not release ticket #{issue.identifier}; its orphaned in-progress claim remains.",
        reason:
          "Ticket #{issue.identifier} has no live runtime, but its compare-and-set transition from in-progress to todo failed (#{inspect(reason)}) and will be retried on a later candidate poll.",
        needs_attention: true,
        severity: "warning",
        central: true
      )
    end

    failures =
      state.startup_claim_reconciliation_failures
      |> Enum.reject(fn {identifier, _reason} -> identifier == issue.identifier end)
      |> MapSet.new()
      |> MapSet.put(signature)

    %{state | startup_claim_reconciliation_failures: failures}
  end

  defp resolve_release_failure(%State{} = state, %Issue{} = issue, opts) do
    {matching, retained} =
      Enum.split_with(state.startup_claim_reconciliation_failures, fn {identifier, _reason} ->
        identifier == issue.identifier
      end)

    if matching != [] do
      emit_alert_fun = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

      emit_alert_fun.(failure_topic(issue) <> ".resolved",
        issue: issue,
        message: "Startup claim reconciliation recovered for ticket #{issue.identifier}.",
        reason: "A fresh tracker snapshot no longer reports an orphaned in-progress claim for ticket #{issue.identifier}.",
        needs_attention: false,
        severity: "info",
        central: true
      )
    end

    %{state | startup_claim_reconciliation_failures: MapSet.new(retained)}
  end

  defp failure_recorded?(%State{} = state, %Issue{} = issue) do
    Enum.any?(state.startup_claim_reconciliation_failures, fn {identifier, _reason} ->
      identifier == issue.identifier
    end)
  end

  defp lifecycle_state_name(opts, slug, fallback) do
    opts
    |> Keyword.get_lazy(:active_states, &Config.active_states/0)
    |> Enum.find(fallback, &(DispatchPolicy.state_slug(&1) == slug))
  end

  defp failure_topic(issue), do: "ticket.#{issue.identifier}.agent.attention.startup_claim_reconciliation_failed"
end
