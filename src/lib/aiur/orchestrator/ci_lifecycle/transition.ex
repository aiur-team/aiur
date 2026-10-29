defmodule Aiur.Orchestrator.CiLifecycle.Transition do
  @moduledoc """
  Fenced CI ticket-state transitions and the CI-wait pause they trigger.
  """

  alias Aiur.Issue
  alias Aiur.Orchestrator.AgentTeardown
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.CiLifecycle.Poll
  alias Aiur.Orchestrator.CiLifecycle.WaitRewake
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.LifecycleFence
  alias Aiur.Orchestrator.PauseResume
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TicketTransition
  require Logger

  # A ticket carrying contradictory `agent:*` state labels has `state: nil`
  # (see `Issues.extract_state/3`). The CI lifecycle must still behave
  # deterministically: `ci-wait` is a transient sub-state, so any other state
  # label on the ticket is the real disposition and takes precedence — a
  # `ci-wait`+`rework` ticket is really rework, a `ci-wait`+`human-review`
  # ticket is really in review and must not be pulled out by a passing verdict.
  # `DispatchPolicy.resolve_state_labels/1` implements exactly that precedence.
  @doc false
  @spec effective_ci_state(Issue.t()) :: term()
  def effective_ci_state(%Issue{state: state}) when is_binary(state), do: state

  def effective_ci_state(%Issue{state_labels: state_labels}) when is_list(state_labels) do
    DispatchPolicy.resolve_state_labels(state_labels)
  end

  def effective_ci_state(_issue), do: nil

  # The `expected_state` guard that protects CI transitions from clobbering a
  # newer legitimate state is only meaningful when the polled ticket had a
  # concrete state. A nil state (contradictory labels) is exactly the case the
  # guard cannot answer — the swap that follows replaces the whole label set, so
  # omitting the guard is the honest repair (#2366).
  @doc false
  @spec expected_state_opts(Issue.t()) :: term()
  def expected_state_opts(%Issue{} = issue) do
    case effective_ci_state(issue) do
      state when is_binary(state) -> [expected_state: state]
      _ -> []
    end
  end

  # The review branches keep a ticket in its review disposition without a state
  # swap, so the running entry must carry the effective (resolved) state rather
  # than the raw polled one: a ticket whose stale `ci-wait` co-owns a review
  # label can arrive with `state: nil`, and persisting that nil into `running`
  # would hide the review disposition from later consumers (#2366).
  @doc false
  @spec effective_issue_state(Issue.t()) :: term()
  def effective_issue_state(%Issue{} = issue) do
    %{issue | state: effective_ci_state(issue)}
  end

  @doc false
  # `on_success` runs only after the tracker write succeeds.
  @spec transition_ci_ticket(State.t(), Issue.t(), String.t(), (State.t() -> State.t()), [String.t()]) :: State.t()
  def transition_ci_ticket(%State{} = state, %Issue{} = issue, next_state, on_success \\ & &1, reason_modifiers \\ []) do
    if LifecycleFence.handoff_blocked?(state, issue) do
      log_fenced_ci_handoff(issue, next_state)
      state
    else
      issue_key = issue.id || issue.identifier

      Poll.run_ci_effect(
        state,
        issue,
        next_state,
        fn -> write_ci_ticket_state({issue, issue_key, next_state, reason_modifiers}) end,
        fn arg1, arg2 ->
          apply_ci_ticket_transition(arg1, arg2, {issue, next_state, on_success})
        end
      )
    end
  end

  defp dispatch_successful_transition(state, issue, next_state) do
    updated_issue = %{issue | state: next_state}

    state =
      if CiLifecycle.ci_wait_state?(next_state),
        do: CiLifecycle.clear_ci_approved_head(state, issue),
        else: state

    cond do
      DispatchPolicy.active_issue_state?(next_state, DispatchPolicy.active_state_set()) ->
        Reconciler.maybe_reactivate_or_refresh(state, updated_issue)

      CiLifecycle.ci_wait_state?(next_state) ->
        pause_issue_for_ci_wait(state, updated_issue)

      true ->
        Reconciler.refresh_running_issue_state(state, updated_issue)
    end
  end

  @doc false
  @spec pause_issue_for_ci_wait(State.t(), Issue.t()) :: State.t()
  def pause_issue_for_ci_wait(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      nil ->
        RetryEngine.release_issue_claim(state, issue.id)

      %{control: %{status: :completed}} = running_entry ->
        state
        |> Reconciler.refresh_running_entry_issue(issue, running_entry)
        |> AgentTeardown.deactivate_running_issue(issue.id)
        |> set_running_paused_reason(issue.id, :ci_wait)
        |> WaitRewake.arm_ci_wait_rewake(issue)

      %{control: %{status: :deactivated}} = running_entry ->
        state
        |> Reconciler.refresh_running_entry_issue(issue, Map.put(running_entry, :paused_reason, :ci_wait))
        |> WaitRewake.arm_ci_wait_rewake(issue)

      %{control: %{status: :paused}, paused_reason: :ci_wait} = running_entry ->
        state
        |> PauseResume.transition_control_status(
          Map.put(running_entry, :issue, issue),
          :paused,
          "ci_wait"
        )
        |> WaitRewake.arm_ci_wait_rewake(issue)

      %{control: %{status: :paused}} = running_entry ->
        pause_already_paused_for_ci_wait(state, issue, running_entry)

      running_entry when is_map(running_entry) ->
        Logger.info("CI wait detected: #{State.issue_context(issue)}; pausing active agent")
        {_reply, state} = PauseResume.request_pause(state, running_entry, issue, :ci_wait)
        WaitRewake.arm_ci_wait_rewake(state, issue)

      _ ->
        state
    end
  end

  defp pause_already_paused_for_ci_wait(state, issue, running_entry) do
    running_entry = Map.put(running_entry, :issue, issue)

    if Map.get(running_entry, :paused_reason) == :blocker_dependency do
      state
      |> PauseResume.transition_control_status(
        Map.put(running_entry, :paused_reason, :ci_wait),
        :paused,
        "ci_wait"
      )
      |> WaitRewake.arm_ci_wait_rewake(issue)
    else
      PauseResume.transition_control_status(state, running_entry, :paused, "ci_wait_suppressed")
    end
  end

  @doc false
  @spec log_fenced_ci_handoff(term(), term()) :: term()
  def log_fenced_ci_handoff(issue, next_state) do
    Logger.warning(
      "CI lifecycle transition fenced until authoritative input reaches the provider: " <>
        "#{State.issue_context(issue)} state=#{next_state}"
    )
  end

  defp set_running_paused_reason(state, issue_id, reason) do
    case Map.get(state.running, issue_id) do
      nil -> state
      entry -> %{state | running: Map.put(state.running, issue_id, Map.put(entry, :paused_reason, reason))}
    end
  end

  defp write_ci_ticket_state({issue, issue_key, next_state, reason_modifiers}) do
    opts = Keyword.merge(expected_state_opts(issue), writer: :ci_lifecycle, reason_modifiers: reason_modifiers, current_labels: List.wrap(issue.labels))
    TicketTransition.write_state(to_string(issue_key), next_state, opts)
  end

  defp apply_ci_ticket_transition(state, response, {issue, next_state, on_success}) do
    case response do
      :ok ->
        state |> on_success.() |> dispatch_successful_transition(issue, next_state)

      {:error, reason} ->
        Logger.warning(
          "CI lifecycle transition skipped: #{State.issue_context(issue)} " <>
            "state=#{next_state} reason=#{inspect(reason)}"
        )

        state
    end
  end
end
