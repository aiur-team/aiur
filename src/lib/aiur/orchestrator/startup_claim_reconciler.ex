defmodule Aiur.Orchestrator.StartupClaimReconciler do
  @moduledoc """
  Releases tracker claims whose runtime did not survive orchestrator startup.

  The first successful candidate poll is the first point where tracker state
  and the current runtime registry can be compared safely. A failed release
  leaves this pass incomplete so a later successful poll retries it.
  """

  require Logger

  alias Aiur.{Alerts, Issue, Tracker}
  alias Aiur.Orchestrator.State

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

  defp reconcile_issue(%State{} = state, %Issue{state: "in-progress", identifier: identifier} = issue, live_identifiers, opts)
       when is_binary(identifier) do
    if MapSet.member?(live_identifiers, identifier) do
      {:ok, state, issue}
    else
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
    update_issue_state_fun =
      Keyword.get(opts, :update_issue_state_fun, fn identifier, state_name, expected_state ->
        Tracker.update_issue_state(identifier, state_name, expected_state: expected_state)
      end)

    case update_issue_state_fun.(issue.identifier, "todo", "in-progress") do
      :ok ->
        Logger.warning("Released orphaned startup claim for ticket #{issue.identifier} to todo; no live runtime owns it")
        emit_released_alert(issue, opts)
        state = resolve_release_failure(state, issue, opts)
        {:ok, state, %{issue | state: "todo"}}

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

    if MapSet.member?(state.startup_claim_reconciliation_failures, signature) do
      state
    else
      Logger.error("Failed to release orphaned startup claim for ticket #{issue.identifier}: #{inspect(reason)}; retrying on a later candidate poll")

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

      failures =
        state.startup_claim_reconciliation_failures
        |> Enum.reject(fn {identifier, _reason} -> identifier == issue.identifier end)
        |> MapSet.new()
        |> MapSet.put(signature)

      %{state | startup_claim_reconciliation_failures: failures}
    end
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
        reason: "The orphaned in-progress claim was successfully released to todo on retry.",
        needs_attention: false,
        severity: "info",
        central: true
      )
    end

    %{state | startup_claim_reconciliation_failures: MapSet.new(retained)}
  end

  defp failure_topic(issue), do: "ticket.#{issue.identifier}.agent.attention.startup_claim_reconciliation_failed"
end
