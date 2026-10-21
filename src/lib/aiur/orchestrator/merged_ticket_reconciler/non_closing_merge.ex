defmodule Aiur.Orchestrator.MergedTicketReconciler.NonClosingMerge do
  @moduledoc false

  alias Aiur.{Issue, RecentMerge, RecentMergeStore, Tracker}
  alias Aiur.Orchestrator.{MergeStateWriter, TicketTransition}

  @pending_states ~w(in-progress ci-wait human-review merging)

  @spec reference_only?(Issue.t(), RecentMerge.t(), keyword()) :: boolean()
  def reference_only?(%Issue{identifier: identifier} = issue, %RecentMerge{} = merge, opts \\ []) do
    marker = Keyword.get(opts, :non_closing_merge_marker, Aiur.Config.settings!().agent.non_closing_merge_marker || "needs-triage")

    merge.ticket_id == identifier and
      String.downcase(to_string(issue.state || "")) in @pending_states and
      marker not in Issue.label_names(issue) and
      identifier in RecentMerge.referenced_issue_identifiers_in_body(merge.summary, merge.repository) and
      identifier not in RecentMerge.closing_issue_identifiers(merge)
  end

  @spec triage_due?(Issue.t(), RecentMerge.t(), keyword()) :: boolean()
  def triage_due?(issue, merge, opts) do
    reference_only?(issue, merge, opts) and not triage_recorded?(merge, issue, opts)
  end

  @spec record_triage(term(), Issue.t(), RecentMerge.t(), keyword(), function(), function()) :: term()
  def record_triage(state, issue, merge, opts, record, alert) do
    persist = Keyword.get(opts, :mark_reference_merge_reconciled_fun, &RecentMergeStore.mark_ticket_reconciled/2)

    case persist.(merge.id, issue.identifier) do
      :ok -> record.(state, issue, merge)
      {:error, reason} -> alert.(state, issue, merge, reason, opts)
      other -> alert.(state, issue, merge, {:unexpected_store_result, other}, opts)
    end
  end

  @spec write_target(Issue.t(), RecentMerge.t(), term(), keyword(), function()) :: :ok | {:error, term()}
  def write_target(issue, merge, expected, opts, update) do
    marker = Keyword.get(opts, :non_closing_merge_marker, Aiur.Config.settings!().agent.non_closing_merge_marker || "needs-triage")
    add_marker = Keyword.get(opts, :add_label_fun, fn id, label -> TicketTransition.write_marker(id, :add, label, writer: :merged_ticket_reconciler) end)
    comment = Keyword.get(opts, :create_comment_fun, fn id, body -> TicketTransition.write_comment(id, body, writer: :merged_ticket_reconciler) end)

    with :ok <- update.(issue.identifier, "human-review", expected),
         :ok <- add_marker.(issue.identifier, marker) do
      comment.(issue.identifier, "Merged PR ##{merge.number} (#{merge.url}) references this ticket without a closing keyword; moved to human-review with `#{marker}` for triage.")
    end
  end

  @spec update_issue_state_fun(keyword()) :: function()
  def update_issue_state_fun(opts) do
    Keyword.get(opts, :update_issue_state_fun, fn identifier, target, expected ->
      TicketTransition.write_state(identifier, target,
        writer: :merged_ticket_reconciler,
        expected_state: expected,
        refuse_labels: MergeStateWriter.operator_hold_labels(),
        tracker: Keyword.get(opts, :tracker, Tracker)
      )
    end)
  end

  defp triage_recorded?(merge, issue, opts) do
    lookup = Keyword.get(opts, :reference_merge_reconciled_fun, &RecentMergeStore.ticket_reconciled?/2)
    lookup.(merge.id, issue.identifier) == true
  rescue
    _error -> true
  catch
    :exit, _reason -> true
  end
end
