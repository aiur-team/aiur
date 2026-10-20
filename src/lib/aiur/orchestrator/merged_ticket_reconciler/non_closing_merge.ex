defmodule Aiur.Orchestrator.MergedTicketReconciler.NonClosingMerge do
  @moduledoc false

  alias Aiur.{Issue, RecentMerge}
  alias Aiur.Orchestrator.TicketTransition

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

  @spec write_target(Issue.t(), RecentMerge.t(), term(), keyword(), function()) :: :ok | {:error, term()}
  def write_target(issue, merge, expected, opts, update) do
    marker = Keyword.get(opts, :non_closing_merge_marker, Aiur.Config.settings!().agent.non_closing_merge_marker || "needs-triage")
    add_marker = Keyword.get(opts, :add_label_fun, fn id, label -> TicketTransition.write_marker(id, :add, label, writer: :merged_ticket_reconciler) end)
    comment = Keyword.get(opts, :create_comment_fun, fn id, body -> TicketTransition.write_comment(id, body, writer: :merged_ticket_reconciler) end)

    with :ok <- add_marker.(issue.identifier, marker),
         :ok <- update.(issue.identifier, "human-review", expected) do
      comment.(issue.identifier, "Merged PR ##{merge.number} (#{merge.url}) references this ticket without a closing keyword; moved to human-review with `#{marker}` for triage.")
    end
  end

  @spec update_issue_state_fun(keyword()) :: function()
  def update_issue_state_fun(opts) do
    Keyword.get(opts, :update_issue_state_fun, fn identifier, target, expected ->
      TicketTransition.write_state(identifier, target, writer: :merged_ticket_reconciler, expected_state: expected)
    end)
  end
end
