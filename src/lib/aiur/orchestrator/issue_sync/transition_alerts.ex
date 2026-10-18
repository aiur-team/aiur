defmodule Aiur.Orchestrator.IssueSync.TransitionAlerts do
  @moduledoc """
  Publishes observed state, pause, and human-review transitions.
  """

  alias Aiur.AlertFeed
  alias Aiur.Alerts
  alias Aiur.Config
  alias Aiur.DispatchBudgetStore
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Issue
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.State

  @doc false
  @spec observe_human_review_handoffs(State.t(), list()) :: State.t()
  def observe_human_review_handoffs(%State{} = state, issues) when is_list(issues) do
    current_ids = MapSet.new(for %Issue{state: state_name, id: id} <- issues, DispatchPolicy.state_slug(state_name) == "human-review", do: id)

    if is_nil(state.human_review_observed_ids) do
      %{state | human_review_observed_ids: current_ids}
    else
      new_ids = MapSet.difference(current_ids, state.human_review_observed_ids)
      state = publish_new_human_review_handoffs(state, issues, new_ids)
      %{state | human_review_observed_ids: current_ids}
    end
  end

  defp publish_new_human_review_handoffs(state, issues, new_ids) do
    Enum.reduce(issues, state, fn
      %Issue{id: id} = issue, state_acc ->
        if MapSet.member?(new_ids, id) do
          publish_human_review_handoff(issue)
          resolve_observed_error_transition_alert(state_acc, issue)
        else
          state_acc
        end

      _issue, state_acc ->
        state_acc
    end)
  end

  @doc false
  @spec active_attention_topics() :: MapSet.t()
  def active_attention_topics do
    [needs_attention: true]
    |> AlertFeed.list()
    |> MapSet.new(& &1["topic"])
  end

  @doc false
  @spec emit_task_state_transition_alert(State.t(), Issue.t() | nil, term()) :: State.t()
  def emit_task_state_transition_alert(%State{} = state, nil, %Issue{} = issue) do
    if DispatchPolicy.state_slug(issue.state) == "error" do
      emit_observed_error_transition_alert(state, issue)
    else
      resolve_observed_error_transition_alert(state, issue)
    end
  end

  def emit_task_state_transition_alert(
        %State{} = state,
        %Issue{} = previous_issue,
        %Issue{} = issue
      ) do
    previous_state = DispatchPolicy.state_slug(previous_issue.state)
    current_state = DispatchPolicy.state_slug(issue.state)

    cond do
      is_nil(current_state) ->
        state

      previous_state == current_state ->
        reconcile_observed_error_alert(state, issue, current_state)

      current_state == "error" ->
        emit_observed_error_transition_alert(state, issue)

      current_state == "human-review" ->
        Alerts.emit_system(
          "ticket.#{issue.identifier}.issue.label.added.agent.human-review",
          issue: issue,
          worker_host: State.WorkerHost.running_worker_host(state, issue.id),
          reason: task_state_alert_reason(current_state),
          needs_attention: task_state_needs_attention?(current_state),
          severity: task_state_alert_severity(current_state)
        )

        publish_human_review_handoff(issue)
        resolve_observed_error_transition_alert(state, issue)

      previous_state == "error" ->
        resolve_observed_error_transition_alert(state, issue)

      true ->
        # Ticket B: label-flip alerts route through the new topic shape so
        # the alerts file can glob-match per state without one entry per state.
        Alerts.emit_system(
          "ticket.#{issue.identifier}.issue.label.added.agent.#{current_state}",
          issue: issue,
          worker_host: State.WorkerHost.running_worker_host(state, issue.id),
          reason: task_state_alert_reason(current_state),
          needs_attention: task_state_needs_attention?(current_state),
          severity: task_state_alert_severity(current_state)
        )

        clear_observed_error_alert(state, issue.id)
    end
  end

  def emit_task_state_transition_alert(%State{} = state, _previous_issue, _issue), do: state

  defp publish_human_review_handoff(%Issue{} = issue) do
    {pr_number, head_sha} = human_review_pr_details(issue)

    Alerts.emit_system("ticket.#{issue.identifier}.agent.handoff.human_review",
      issue: issue,
      reason: "Agent handed the ticket to human review",
      needs_attention: true,
      severity: "warning",
      exchange_payload: %{
        "action" => "human_review",
        "pr_number" => pr_number,
        "head_sha" => head_sha
      }
    )
  end

  defp human_review_pr_details(%Issue{tracker_identity: %{kind: :github, owner: owner, repository: repository}, id: id})
       when is_binary(id) do
    key = ResourceStore.key_for_repo(:branch_pull_request_listing, "#{owner}/#{repository}", id)
    key |> ResourceStore.data() |> human_review_pr_listing_identity()
  rescue
    _ -> {nil, nil}
  end

  defp human_review_pr_details(_issue), do: {nil, nil}

  defp human_review_pr_listing_identity(%{} = pull_request), do: human_review_pr_identity(pull_request)

  defp human_review_pr_listing_identity([pull_request | _rest]), do: human_review_pr_identity(pull_request)

  defp human_review_pr_listing_identity(_listing), do: {nil, nil}

  defp human_review_pr_identity(%{"number" => number, "head" => %{"sha" => sha}}) when is_integer(number) and is_binary(sha),
    do: {number, sha}

  defp human_review_pr_identity(_pull_request), do: {nil, nil}

  defp reconcile_observed_error_alert(state, issue, "error"),
    do: emit_observed_error_transition_alert(state, issue)

  defp reconcile_observed_error_alert(state, issue, _state),
    do: resolve_observed_error_transition_alert(state, issue)

  defp emit_observed_error_transition_alert(%State{} = state, %Issue{} = issue) do
    cause = observed_error_alert_cause(state, issue)
    topic = observed_error_alert_topic(issue, cause)

    if MapSet.member?(state.observed_error_alerts, issue.id) or active_attention?(state, topic) do
      mark_observed_error_alert(state, issue.id, cause)
    else
      message = observed_error_alert_message(cause)

      case Alerts.emit_system(topic,
             issue: issue,
             worker_host: State.WorkerHost.running_worker_host(state, issue.id),
             reason: message,
             needs_attention: true,
             severity: "warning",
             central: true
           ) do
        :ok -> mark_observed_error_alert(state, issue.id, cause)
        {:error, _reason} -> state
      end
    end
  end

  defp resolve_observed_error_transition_alert(%State{} = state, %Issue{} = issue) do
    cause = observed_error_alert_cause(state, issue)
    topic = observed_error_alert_topic(issue, cause)

    active? =
      MapSet.member?(state.observed_error_alerts, issue.id) or
        active_attention?(state, topic)

    cond do
      cause == :lifetime_latch and lifetime_latch_status(state, issue.id) != :inactive ->
        mark_observed_error_alert(state, issue.id, cause)

      active? ->
        case Alerts.emit_system("#{topic}.resolved",
               issue: issue,
               worker_host: State.WorkerHost.running_worker_host(state, issue.id),
               reason: "Tracker moved the ticket out of agent:error; the observed error condition is resolved.",
               needs_attention: false,
               severity: "info",
               central: true
             ) do
          :ok -> clear_observed_error_alert(state, issue.id)
          {:error, _reason} -> state
        end

      true ->
        state
    end
  end

  defp observed_error_alert_cause(%State{} = state, %Issue{} = issue) do
    cond do
      lifetime_latch_active?(state, issue.id) -> :lifetime_latch
      cause = Map.get(state.observed_error_alert_causes, issue.id) -> cause
      cause = persisted_observed_error_alert_cause(state, issue) -> cause
      true -> :observed_tracker_error
    end
  end

  defp persisted_observed_error_alert_cause(%State{} = state, %Issue{} = issue) do
    Enum.find([:lifetime_latch, :retry_exhausted, :observed_tracker_error], fn cause ->
      active_attention?(state, observed_error_alert_topic(issue, cause))
    end)
  end

  @doc false
  @spec active_attention?(State.t(), String.t()) :: boolean()
  def active_attention?(state, topic), do: MapSet.member?(state.active_attention_topics, topic)

  @doc false
  @spec stranded_attention_cleared?(State.t(), Issue.t(), MapSet.t()) :: boolean()
  def stranded_attention_cleared?(%State{} = state, %Issue{} = issue, terminal_states) when is_struct(terminal_states, MapSet) do
    topic = "ticket.#{issue.identifier}.agent.attention.stranded-requeued"
    state_slug = DispatchPolicy.state_slug(issue.state)

    no_longer_dispatchable? =
      state_slug in ["ci-wait", "merging"] or DispatchPolicy.terminal_issue_state?(issue.state, terminal_states)

    no_longer_dispatchable? and active_attention?(state, topic)
  end

  defp lifetime_latch_active?(%State{} = state, issue_id) when is_binary(issue_id) do
    lifetime_latch_status(state, issue_id) == :active
  end

  defp lifetime_latch_active?(_state, _issue_id), do: false

  defp lifetime_latch_status(%State{} = state, issue_id) when is_binary(issue_id) do
    maximum = Config.agent_max_dispatches_per_ticket()
    budget = get_in(state.dispatch_recovery, [:codex_thrash_budget, issue_id]) || %{}

    # A trip recorded in the live recovery state remains authoritative until
    # the dispatch budget explicitly clears it. Configuration may be reloaded
    # between the trip and this tracker observation, so do not reinterpret an
    # already-recorded latch through the current cap.
    memory_latched? = budget[:tripped] == :lifetime

    if memory_latched?, do: :active, else: persisted_latch_status(maximum, issue_id)
  end

  defp lifetime_latch_status(_state, _issue_id), do: :inactive

  defp persisted_latch_status(maximum, issue_id) when maximum > 0 do
    case DispatchBudgetStore.lifetime(issue_id) do
      {:ok, lifetime} when lifetime >= maximum -> :active
      {:ok, _lifetime} -> :inactive
      {:error, _reason} -> :unknown
    end
  end

  defp persisted_latch_status(_maximum, _issue_id), do: :inactive

  defp observed_error_alert_message(:lifetime_latch),
    do: "Agent remains in error because its lifetime dispatch latch is still active; Executor action is required."

  defp observed_error_alert_message(_cause),
    do:
      "Tracker observed agent:error without a specialized local cause; the ticket needs Executor review. " <>
        "This condition will not clear on its own until the ticket is moved out of error."

  defp observed_error_alert_topic(%Issue{} = issue, cause) do
    "ticket.#{issue.identifier}.agent.attention.error-#{cause}"
  end

  defp mark_observed_error_alert(state, issue_id, cause) do
    %{
      state
      | observed_error_alerts: MapSet.put(state.observed_error_alerts, issue_id),
        observed_error_alert_causes: Map.put(state.observed_error_alert_causes, issue_id, cause)
    }
  end

  defp clear_observed_error_alert(state, issue_id) do
    %{
      state
      | observed_error_alerts: MapSet.delete(state.observed_error_alerts, issue_id),
        observed_error_alert_causes: Map.delete(state.observed_error_alert_causes, issue_id)
    }
  end

  @doc false
  @spec emit_tracker_pause_transition_alert(State.t(), Issue.t() | nil, term()) :: State.t()
  def emit_tracker_pause_transition_alert(%State{} = state, nil, %Issue{} = issue) do
    if Issue.paused?(issue) do
      emit_tracker_pause_alert(state, issue)
    else
      resolve_tracker_pause_alert(state, issue)
    end

    state
  end

  def emit_tracker_pause_transition_alert(
        %State{} = state,
        %Issue{} = previous_issue,
        %Issue{} = issue
      ) do
    case {Issue.paused?(previous_issue), Issue.paused?(issue)} do
      {false, true} ->
        emit_tracker_pause_alert(state, issue)

      {true, false} ->
        Alerts.emit_system("ticket.#{issue.identifier}.agent.unpaused",
          issue: issue,
          worker_host: State.WorkerHost.running_worker_host(state, issue.id),
          reason: "Tracker removed agent:paused; tracker=agent:#{issue.state}. No operator action is needed.",
          needs_attention: false,
          severity: "info"
        )

        resolve_tracker_pause_alert(state, issue, true)

      _ ->
        :ok
    end

    state
  end

  def emit_tracker_pause_transition_alert(%State{} = state, _previous_issue, _issue), do: state

  defp emit_tracker_pause_alert(%State{} = state, %Issue{} = issue) do
    topic = "ticket.#{issue.identifier}.agent.paused"

    unless active_attention?(state, topic) do
      Alerts.emit_system(topic,
        issue: issue,
        worker_host: State.WorkerHost.running_worker_host(state, issue.id),
        reason:
          "Tracker added agent:paused (tracker pause override); tracker=agent:#{issue.state}. " <>
            "This clears when the operator removes agent:paused.",
        needs_attention: true,
        severity: "warning",
        central: true
      )
    end
  end

  defp resolve_tracker_pause_alert(state, issue), do: resolve_tracker_pause_alert(state, issue, false)

  defp resolve_tracker_pause_alert(%State{} = state, %Issue{} = issue, force?) do
    topic = "ticket.#{issue.identifier}.agent.paused"

    if force? or active_attention?(state, topic) do
      Alerts.emit_system("#{topic}.resolved",
        issue: issue,
        worker_host: State.WorkerHost.running_worker_host(state, issue.id),
        reason: "Tracker removed agent:paused; the tracker pause override is resolved.",
        needs_attention: false,
        severity: "info",
        central: true
      )
    else
      :ok
    end
  end

  defp task_state_alert_reason("human-review"),
    do: "Agent marked the ticket ready for human review"

  defp task_state_alert_reason(_state), do: nil

  defp task_state_needs_attention?("human-review"), do: true
  defp task_state_needs_attention?(_state), do: false

  defp task_state_alert_severity("human-review"), do: "warning"
  defp task_state_alert_severity(_state), do: nil
end
