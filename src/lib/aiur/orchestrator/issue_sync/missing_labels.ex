defmodule Aiur.Orchestrator.IssueSync.MissingLabels do
  @moduledoc """
  Restores missing state labels only with prior workflow evidence.
  """

  require Logger

  alias Aiur.Alerts
  alias Aiur.GitHub.StatePolicy
  alias Aiur.Issue
  alias Aiur.Orchestrator.IssueSync.LabelWrites
  alias Aiur.Orchestrator.IssueSync.TransitionAlerts
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerTasks

  # A ticket observed with zero `agent:*` state labels is invisible to dispatch
  # (#2420): every reconciler consumes either the filtered candidate list or
  # `state.running`, and a zero-label ticket is in neither, so nothing would
  # ever repair a genuine strand. But zero labels is *also* a documented,
  # intentional state — deliberately parked work carries `needs-triage`,
  # `human:todo`, or an `Epic:` marker with no state label, and a fresh issue
  # nobody has triaged has neither — so the repair must be evidence-gated, not
  # shape-gated: never touch a parked-marker ticket, restore the last known
  # state only when a prior running/last-polled entry carries one, and when
  # there is no evidence at all alert without writing and leave the labels
  # alone (#2420).
  #
  # `agent:paused` is a marker suffix, not a state suffix, so an operator-gated
  # ticket carrying only `agent:paused` normalizes to zero state labels. It is
  # the documented parking marker for deliberately held work, so it gates the
  # heal exactly like `agent:parked` — otherwise every poll of a paused ticket
  # raised a false `state-label-missing-no-evidence` attention (#2610).
  # `agent:queued` likewise parks marker-only work until the queue releases it.
  @doc false
  @spec heal_or_leave_missing_state_label(Issue.t(), State.t(), (String.t(), String.t() -> :ok | {:error, term()})) :: {Issue.t() | nil, State.t()}
  def heal_or_leave_missing_state_label(%Issue{} = issue, state, update_state_fun) do
    cond do
      Issue.paused?(issue) or Issue.parked?(issue) or Issue.queued?(issue) or parked_marker?(issue) ->
        {issue, state}

      restore_target_for(issue, state) == nil ->
        # Evidence of workflow membership exists (e.g. a released claim) but
        # there is no non-terminal state to restore; leave the ticket for the
        # sweep, whose re-queue falls back to `agent:todo`.
        {issue, state}

      true ->
        heal_missing_state_label(issue, state, update_state_fun)
    end
  end

  defp heal_missing_state_label(%Issue{} = issue, state, update_state_fun) do
    if TrackerTasks.owner?(state) do
      LabelWrites.schedule_label_heal(state, issue, restore_target_for(issue, state) || "todo", update_state_fun, &heal_missing_state_label_sync/3)
    else
      heal_missing_state_label_sync(issue, state, update_state_fun)
    end
  end

  defp heal_missing_state_label_sync(%Issue{} = issue, state, update_state_fun) do
    restored = restore_target_for(issue, state) || "todo"
    healed_issue = %{issue | state: restored, state_labels: [restored]}

    case update_state_fun.(issue.identifier, restored) do
      :ok ->
        alert_missing_state_label_repaired(issue, restored)

        Logger.warning("Healing missing state label for #{State.issue_context(issue)} -> #{restored}")

        {healed_issue, %{state | last_polled_issues: Map.put(state.last_polled_issues, issue.id, healed_issue)}}

      {:error, reason} ->
        Logger.warning("Missing state label heal failed for #{State.issue_context(issue)}: #{inspect(reason)}; dispatching on restored state")

        {healed_issue, state}
    end
  end

  # The last known state comes from the running entry's issue (the state its
  # agent was last dispatched under) or the previous polled copy. A running
  # entry is authoritative; the previous poll is the fallback so a swap that
  # removed the label between polls still restores the pre-transition state.
  defp prior_workflow_state(%Issue{id: issue_id}, %State{} = state) do
    workflow_state_from(Map.get(state.running, issue_id)) ||
      workflow_state_from(Map.get(state.last_polled_issues, issue_id))
  end

  defp prior_workflow_state(_issue, _state), do: nil

  # A non-empty state name from a running entry (`%{issue: %Issue{}}` or
  # `%{issue: %{}}`) or a prior polled copy (`%Issue{}` or `%{}`). Running
  # entries wrap the issue under `:issue`; a polled copy is the issue itself.
  defp workflow_state_from(%{issue: issue}) when is_map(issue), do: workflow_state_from(issue)
  defp workflow_state_from(%Issue{state: state_name}) when is_binary(state_name) and state_name != "", do: state_name
  defp workflow_state_from(%{state: state_name}) when is_binary(state_name) and state_name != "", do: state_name
  defp workflow_state_from(_entry), do: nil

  # The state to restore a stranded ticket to. Only a non-terminal state is a
  # safe restore target; a terminal prior state (or no prior state at all)
  # yields nil so the caller alerts without writing rather than guessing.
  defp restore_target_for(%Issue{} = issue, %State{} = state) do
    case prior_workflow_state(issue, state) do
      nil -> nil
      state_name -> if StatePolicy.terminal_state_name?(state_name), do: nil, else: state_name
    end
  end

  # The sweep's restore target: a non-terminal prior state when one exists,
  # else `agent:todo`. The sweep only re-queues a ticket after its own
  # evidence gate (`workflow_evidence?/2`) has passed, so `todo` here is a
  # documented fallback for a ticket whose workflow record is a released claim
  # rather than a running/last-polled state (#2420).
  @doc false
  @spec restore_state_for(Issue.t(), State.t()) :: String.t()
  def restore_state_for(%Issue{} = issue, %State{} = state) do
    restore_target_for(issue, state) || "todo"
  end

  # Positive evidence the ticket was in the agent workflow: a live running
  # entry, a released claim (a claim was dropped), or a prior polled copy
  # carrying a state. No evidence means there is no Executor wake (#4610).
  @doc false
  @spec workflow_evidence?(State.t(), Issue.t()) :: boolean()
  def workflow_evidence?(%State{} = state, %Issue{id: issue_id} = issue) do
    Map.has_key?(state.running, issue_id) or
      Map.has_key?(state.released_claims, issue_id) or
      is_binary(prior_workflow_state(issue, state))
  end

  # Deliberately parked work carries a non-state marker instead of an `agent:*`
  # state label — `needs-triage`, `human:todo`, or an `Epic:` container (the
  # explicit `agent:parked` marker is surfaced separately as `Issue.parked?`).
  # Such tickets must never be rewritten to `agent:todo`: that would silently
  # reverse deliberate parking and make `human:todo` tickets dispatchable, the
  # exact boundary that label protects (#2420).
  @doc false
  @spec parked_marker?(Issue.t()) :: boolean()
  def parked_marker?(%Issue{labels: labels}) do
    Enum.any?(labels, &parked_marker_label?/1)
  end

  defp parked_marker_label?(label) when is_binary(label) do
    label = label |> String.trim() |> String.downcase()
    label in ["needs-triage", "human:todo"] or String.starts_with?(label, "epic:")
  end

  defp parked_marker_label?(_label), do: false

  @doc false
  @spec resolve_missing_state_label_alert(term(), State.t()) :: State.t()
  def resolve_missing_state_label_alert(%Issue{state_labels: [_ | _]} = issue, %State{} = state) do
    topic = "ticket.#{issue.identifier}.agent.attention.state-label-missing-no-evidence"

    if TransitionAlerts.active_attention?(state, topic) do
      case Alerts.emit_system("#{topic}.resolved",
             issue: issue.identifier,
             reason: "Tracker observation confirms a lifecycle label exists again.",
             needs_attention: false,
             severity: "info",
             central: true
           ) do
        :ok -> %{state | active_attention_topics: MapSet.delete(state.active_attention_topics, topic)}
        {:error, _reason} -> state
      end
    else
      state
    end
  end

  def resolve_missing_state_label_alert(_issue, state), do: state

  defp alert_missing_state_label_repaired(%Issue{} = issue, restored) do
    Alerts.emit_system("ticket.#{issue.identifier}.agent.attention.state-label-missing",
      issue: issue.identifier,
      message: "Ticket #{issue.identifier} had no agent state label and was invisible to dispatch; repaired to #{restored}.",
      reason:
        "Ticket #{issue.identifier} carried zero agent:* state labels (a broken remove-then-add swap left it stranded); " <>
          "restored #{restored} so dispatch can see it again.",
      needs_attention: true,
      severity: "warning",
      central: true
    )
  end
end
