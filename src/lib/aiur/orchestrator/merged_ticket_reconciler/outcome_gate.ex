defmodule Aiur.Orchestrator.MergedTicketReconciler.OutcomeGate do
  @moduledoc false

  alias Aiur.Commands
  alias Aiur.Commands.OutcomeGate
  alias Aiur.Orchestrator.{Lifecycle, MergeStateWriter, Reconciler, TrackerTasks}
  alias Aiur.Orchestrator.MergedTicketReconciler.ClosedRepair
  alias Aiur.PostDeployChecklist

  @spec hold_open(map(), map(), map(), keyword(), list(), function()) :: {map(), list()}
  def hold_open(state, issue, merge, opts, retained, failed_fun) do
    update =
      Keyword.get(opts, :update_issue_state_fun, fn identifier, target, expected ->
        MergeStateWriter.write_reconciler_transition(identifier, target, expected, opts)
      end)

    case update.(issue.identifier, "human-review", expected_state(issue)) do
      :ok -> {state, [issue | retained]}
      {:error, reason} -> {failed_fun.(state, issue, merge, reason, opts), [issue | retained]}
    end
  end

  @spec reconcile_closed(map(), [map()], [map()], DateTime.t(), keyword(), map()) :: map()
  def reconcile_closed(state, issues, merges, now, opts, callbacks) do
    opts = Keyword.put_new(opts, :repair_outcome_gate_issue_fun, &closed_gate_required?/1)

    target_fun = fn issue, opts ->
      target_for_issue(issue, opts, callbacks.closed_without_state_label, callbacks.merged_ticket_target)
    end

    ClosedRepair.reconcile(state, issues, merges, now, opts, callbacks.record, fn state, issue, merge, opts ->
      repair_closed_issue(state, issue, merge, opts, target_fun, callbacks.failed, callbacks.reconciled, callbacks.record)
    end)
  end

  @spec start_handoff(map(), map(), map(), keyword(), function()) :: map()
  def start_handoff(state, issue, merge, opts, failed_fun) do
    input = Reconciler.issue_input(state, issue.id)

    update =
      Keyword.get(opts, :update_issue_state_fun, fn identifier, target, expected ->
        MergeStateWriter.write_reconciler_transition(identifier, target, expected, opts)
      end)

    TrackerTasks.run(
      state,
      {:merged_reconcile, issue.id},
      fn -> update.(issue.identifier, "human-review", expected_state(issue)) end,
      &apply_handoff_result(&1, &2, input, issue, merge, opts, failed_fun)
    )
  end

  defp apply_handoff_result(current, result, input, issue, merge, opts, failed_fun) do
    if Reconciler.issue_input(current, issue.id) == input do
      handoff_result(current, result, issue, merge, opts, failed_fun)
    else
      Lifecycle.wake_tick(current)
    end
  end

  defp handoff_result(current, :ok, _issue, _merge, _opts, _failed_fun), do: current

  defp handoff_result(current, {:error, reason}, issue, merge, opts, failed_fun),
    do: failed_fun.(current, issue, merge, reason, opts)

  @spec repair_closed_issue(map(), map(), map(), keyword(), function(), function(), function(), function()) :: map()
  def repair_closed_issue(state, issue, merge, opts, target_fun, failed_fun, reconciled_fun, record_fun) do
    update =
      Keyword.get(opts, :update_issue_state_fun, fn identifier, target, expected ->
        MergeStateWriter.write_reconciler_transition(identifier, target, expected, opts)
      end)

    case target_fun.(issue, opts) do
      {:ok, {:outcome_gate, "human-review"}} ->
        update_closed_issue(state, issue, merge, opts, update, "human-review", failed_fun)

      {:ok, target} when is_binary(target) ->
        case update.(issue.identifier, target, :none) do
          :ok when target == "done" ->
            reconciled_fun.(issue, merge, 0, 0, opts)
            record_fun.(state, issue, merge)

          :ok ->
            state

          {:error, reason} ->
            failed_fun.(state, issue, merge, reason, opts)
        end

      {:error, reason} ->
        failed_fun.(state, issue, merge, reason, opts)
    end
  end

  @spec target_for_issue(map(), keyword(), function(), function()) :: {:ok, term()} | {:error, term()}
  def target_for_issue(issue, opts, closed_without_state_label_fun, merged_ticket_target_fun) do
    case target(issue, opts) do
      {:ok, {:outcome_gate, "human-review"} = held} ->
        {:ok, held}

      {:error, _reason} = error ->
        error

      {:ok, "done"} ->
        if closed_without_state_label_fun.(issue),
          do: {:ok, "done"},
          else: merged_ticket_target_fun.(issue.identifier, opts)
    end
  end

  @spec closed_gate_required?(map()) :: boolean()
  def closed_gate_required?(issue) do
    labels = issue.labels || []

    if Enum.any?(labels, &(&1 in ["creator-facing", "epic"])) do
      true
    else
      case {PostDeployChecklist.status(), PostDeployChecklist.list()} do
        {:ok, checks} when is_list(checks) -> Enum.any?(checks, &(&1["ticket"] == issue.identifier and is_nil(&1["done_at"])))
        _unavailable -> true
      end
    end
  rescue
    _error -> true
  catch
    :exit, _reason -> true
  end

  defp update_closed_issue(state, issue, merge, opts, update, target, failed_fun) do
    case update.(issue.identifier, target, :none) do
      :ok -> state
      {:error, reason} -> failed_fun.(state, issue, merge, reason, opts)
    end
  end

  defp target(issue, opts) do
    labels = issue.labels || []
    decisions_fun = Keyword.get(opts, :outcome_decisions_fun, &Commands.list_decisions/0)
    checklist_status_fun = Keyword.get(opts, :post_deploy_checklist_status_fun, &PostDeployChecklist.status/0)
    checklist_fun = Keyword.get(opts, :post_deploy_checks_fun, &PostDeployChecklist.list/0)
    decisions = if "creator-facing" in labels, do: decisions_fun.(), else: []

    with true <- is_list(decisions),
         :ok <- checklist_status_fun.(),
         checks when is_list(checks) <- checklist_fun.(),
         {:ok, result} <- merge_target(issue, labels, decisions, checks, opts) do
      {:ok, result}
    else
      {:error, reason} -> {:error, {:outcome_evidence_unavailable, reason}}
      _other -> {:error, :outcome_evidence_unavailable}
    end
  rescue
    _error -> {:error, :outcome_evidence_unavailable}
  catch
    :exit, _reason -> {:error, :outcome_evidence_unavailable}
  end

  defp merge_target(issue, labels, decisions, checks, opts) do
    result = OutcomeGate.merge_target(labels, issue.identifier, decisions, checks)

    cond do
      result == "human-review" -> {:ok, {:outcome_gate, result}}
      result == "done" and "epic" in labels -> epic_target(issue, opts)
      true -> {:ok, result}
    end
  end

  defp epic_target(issue, opts) do
    fetch = Keyword.get(opts, :related_issue_fetcher, fn ids -> Aiur.Tracker.fetch_issue_states_by_ids_conditional(ids, %{}) end)

    with {:ok, %{children: children, followups: followups}} <- OutcomeGate.related_issue_ids(issue.description),
         ids = Enum.uniq(children ++ followups),
         {:ok, related, _cache} <- fetch.(ids),
         true <- is_list(related),
         true <- Enum.all?(ids, &Enum.any?(related, fn item -> to_string(item.identifier) == &1 end)) do
      {child_rows, followup_rows} = Enum.split_with(related, &(to_string(&1.identifier) in children))

      if OutcomeGate.related_work_complete?(rows(child_rows), rows(followup_rows)),
        do: {:ok, "done"},
        else: {:ok, {:outcome_gate, "human-review"}}
    else
      {:error, reason} -> {:error, {:epic_outcome_evidence_unavailable, reason}}
      _other -> {:error, :epic_outcome_evidence_unavailable}
    end
  rescue
    _error -> {:error, :epic_outcome_evidence_unavailable}
  catch
    :exit, _reason -> {:error, :epic_outcome_evidence_unavailable}
  end

  defp rows(issues) do
    Enum.map(issues, fn issue ->
      labels = issue.labels || []
      %{state: issue.state, triaged?: not Enum.any?(labels, &triage_label?/1)}
    end)
  end

  defp triage_label?(label) when is_binary(label) do
    String.downcase(label) in ["needs-triage", "agent:needs-triage", "nuc:needs-triage"]
  end

  defp triage_label?(_label), do: false

  defp expected_state(%{state: state, state_labels: labels}) when labels in [nil, []], do: state || :none
  defp expected_state(_issue), do: :none
end
