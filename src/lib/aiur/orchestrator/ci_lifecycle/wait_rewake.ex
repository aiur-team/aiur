defmodule Aiur.Orchestrator.CiLifecycle.WaitRewake do
  @moduledoc """
  Arms, cancels, and handles the CI-wait fallback re-wake, and resumes a waiting runner on a terminal result.
  """

  alias Aiur.Config
  alias Aiur.Events
  alias Aiur.Events.GithubCIPoller
  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.CiLifecycle.Poll
  alias Aiur.Orchestrator.CiLifecycle.Transition
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.LifecycleFence
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.PauseResume
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Tracker
  require Logger

  @active_handoff_state "in-progress"

  @doc false
  @spec arm_ci_wait_rewake(State.t(), Issue.t()) :: State.t()
  def arm_ci_wait_rewake(%State{} = state, %Issue{id: issue_id} = issue)
      when is_binary(issue_id) do
    rewakes = ci_wait_rewakes(state)

    if Map.has_key?(rewakes, issue_id) do
      state
    else
      delay_ms = Config.ci_wait_rewake_minutes() * 60_000
      token = make_ref()
      timer_ref = Process.send_after(self(), {:ci_wait_rewake, issue_id, token}, delay_ms)

      rewake = %{
        timer_ref: timer_ref,
        token: token,
        identifier: issue.identifier || issue_id,
        deadline_ms: System.monotonic_time(:millisecond) + delay_ms
      }

      put_ci_wait_rewakes(state, Map.put(rewakes, issue_id, rewake))
    end
  end

  def arm_ci_wait_rewake(%State{} = state, _issue), do: state

  @doc false
  @spec cancel_ci_wait_rewake(State.t(), String.t() | nil) :: State.t()
  def cancel_ci_wait_rewake(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.pop(ci_wait_rewakes(state), issue_id) do
      {%{timer_ref: timer_ref}, remaining} ->
        if is_reference(timer_ref), do: Process.cancel_timer(timer_ref)
        put_ci_wait_rewakes(state, remaining)

      {nil, _remaining} ->
        state
    end
  end

  def cancel_ci_wait_rewake(%State{} = state, _issue_id), do: state

  @doc false
  @spec handle_ci_wait_rewake(State.t(), String.t(), reference(), keyword()) :: State.t()
  def handle_ci_wait_rewake(%State{} = state, issue_id, token, opts \\ [])
      when is_binary(issue_id) and is_reference(token) do
    rewakes = ci_wait_rewakes(state)

    case Map.get(rewakes, issue_id) do
      %{token: ^token} ->
        state = put_ci_wait_rewakes(state, Map.delete(rewakes, issue_id))
        issue_fetcher = Keyword.get(opts, :issue_fetcher, &Tracker.fetch_issue_states_by_ids/1)
        handle_current_ci_wait_rewake(state, issue_id, issue_fetcher)

      _ ->
        state
    end
  end

  defp maybe_reactivate_after_ci_wait_fallback(state, issue) do
    if Issue.paused?(issue) do
      Reconciler.refresh_running_issue_state(state, issue)
    else
      case Map.get(state.running, issue.id) do
        %{control: %{status: :paused}, paused_reason: :label_override} ->
          Reconciler.refresh_running_issue_state(state, issue)

        _ ->
          Reconciler.maybe_reactivate_or_refresh(state, issue)
      end
    end
  end

  defp handle_current_ci_wait_rewake(state, issue_id, issue_fetcher) do
    issue = get_in(state.running, [issue_id, :issue])

    if is_struct(issue, Issue) do
      Poll.run_ci_effect(state, issue, :rewake_fetch, fn -> fetch_ci_wait_issue({issue_fetcher, issue_id}) end, fn arg1, arg2 ->
        apply_ci_wait_revalidation(arg1, arg2, {issue_id})
      end)
    else
      state
    end
  end

  defp maybe_rewake_current_ci_wait(state, issue) do
    case Map.get(state.running, issue.id) do
      %{control: %{status: status}, paused_reason: :ci_wait} = running_entry
      when status in [:paused, :deactivated] ->
        rewake_ci_wait_entry(state, issue, running_entry)

      _ ->
        state
    end
  end

  defp rewake_ci_wait_entry(state, issue, running_entry) do
    cond do
      not CiLifecycle.ci_wait_state?(Transition.effective_ci_state(issue)) ->
        resolve_departed_ci_wait(state, issue, running_entry)

      Issue.paused?(issue) ->
        Reconciler.refresh_running_entry_issue(state, issue, running_entry)

      GithubCIPoller.attention_hold?(get_in(state.ci_lifecycle, [:poll_cache, CiLifecycle.ci_target_for_issue(issue)])) ->
        cancel_ci_wait_rewake(state, issue.id)

      approved_pr_in_merge_queue?(state, issue) ->
        cancel_ci_wait_rewake(state, issue.id)

      not DispatchPolicy.issue_routable_to_worker?(issue) ->
        state

      true ->
        transition_ci_wait_fallback(state, issue)
    end
  end

  defp approved_pr_in_merge_queue?(state, issue) do
    target = CiLifecycle.ci_target_for_issue(issue)

    case get_in(state.ci_lifecycle, [:poll_cache, target]) do
      %{review_decision: "APPROVED", merge_queue_entry: %{"state" => "UNMERGEABLE"}} -> false
      %{review_decision: "APPROVED", auto_merge_request: auto_merge} when is_map(auto_merge) -> true
      %{review_decision: "APPROVED", merge_queue_entry: entry} when is_map(entry) -> true
      _other -> false
    end
  end

  # The ticket left `ci-wait` while its agent is still parked with
  # `paused_reason: :ci_wait`, and this timer is the last one armed for it:
  # `handle_ci_wait_rewake/4` has already dropped the rewake from the map, and
  # the CI poll only reads tickets in `ci-wait`/`human-review`
  # (`@ci_poll_states`), so no CI verdict will ever be produced for this ticket
  # again. Returning `state` here therefore strands the agent paused
  # "(CI waiting)" forever on a pull request whose checks are green — the
  # aiur-team/khala stall where #138 and #146 sat parked with
  # `pause_reason=ci_wait` while their tracker label had already moved to
  # `agent:rework`.
  #
  # Hand the ticket back to the ordinary reconcile for the state it is actually
  # in. An active state resumes the parked agent (Reconciler's `:ci_wait` pause
  # branch); anything else — operator-paused, routed away, `human-review`
  # (which the CI poll still covers), terminal — only refreshes the entry,
  # exactly as before.
  defp resolve_departed_ci_wait(state, issue, running_entry) do
    issue = Transition.effective_issue_state(issue)

    if resumable_departed_ci_wait?(issue, running_entry) do
      Reconciler.maybe_reactivate_or_refresh(state, issue)
    else
      Reconciler.refresh_running_entry_issue(state, issue, running_entry)
    end
  end

  # Scoped to a *paused* entry: that is the stranded shape, and it is the one
  # `Reconciler.maybe_reactivate_or_refresh/2` resumes through its `:ci_wait`
  # pause branch. A deactivated entry keeps the previous behaviour.
  defp resumable_departed_ci_wait?(%Issue{} = issue, running_entry) do
    get_in(running_entry, [:control, :status]) == :paused and
      not Issue.paused?(issue) and
      DispatchPolicy.issue_routable_to_worker?(issue) and
      DispatchPolicy.active_issue_state?(issue.state, DispatchPolicy.active_state_set())
  end

  defp transition_ci_wait_fallback(state, issue) do
    if LifecycleFence.handoff_blocked?(state, issue) do
      Transition.log_fenced_ci_handoff(issue, @active_handoff_state)
      arm_ci_wait_rewake(state, issue)
    else
      Poll.run_ci_effect(
        state,
        issue,
        "transition_ci_wait_fallback",
        fn -> write_ci_wait_fallback_state({issue}) end,
        fn arg1, arg2 ->
          apply_ci_wait_fallback_transition(arg1, arg2, {issue})
        end
      )
    end
  end

  defp enqueue_ci_wait_rewake_handoff(state, issue) do
    identifier = issue.identifier || issue.id

    message =
      "No terminal CI event arrived before the fallback timeout. " <>
        "Check CI once. Drafts never pass CI in any repository; mark completed, self-reviewed work ready before waiting. " <>
        "Before agent:human-review, require the full required-check set to pass on the current head SHA. " <>
        "A green or skipped gh pr checks aggregate alone is not a full pass; otherwise return to agent:ci-wait without polling."

    event = %{
      id: Events.next_id(),
      topic: "ticket.#{identifier}.ci.rewake",
      source: :system,
      reason: :ci_wait_timeout,
      timeout_minutes: Config.ci_wait_rewake_minutes(),
      message: message
    }

    OperatorMessages.enqueue_event_digest_item(state, identifier, [event], event)
  end

  defp rearm_ci_wait_rewake(state, issue_id) do
    case Map.get(state.running, issue_id) do
      %{issue: %Issue{} = issue, control: %{status: :paused}, paused_reason: :ci_wait} ->
        arm_ci_wait_rewake(state, issue)

      %{issue: %Issue{} = issue, control: %{status: :deactivated}, paused_reason: :ci_wait} ->
        arm_ci_wait_rewake(state, issue)

      _ ->
        state
    end
  end

  defp maybe_resume_ci_wait_runner(state, running_entry, identifier) do
    issue = Map.get(running_entry, :issue)

    if Issue.paused?(issue) do
      state
    else
      case get_in(running_entry, [:control, :status]) do
        :deactivated -> Reconciler.maybe_reactivate_or_refresh(state, issue)
        _ -> resume_ci_wait_runner(state, running_entry, identifier)
      end
    end
  end

  @doc false
  @spec revalidate_ci_terminal_wake(State.t(), term(), term(), term(), term()) :: term()
  def revalidate_ci_terminal_wake(state, running_entry, identifier, outcome, issue_fetcher) do
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])

    issue = Map.fetch!(running_entry, :issue)

    Poll.run_ci_effect(state, issue, :terminal_fetch, fn -> issue_fetcher.([issue_id]) end, fn state, response ->
      case response do
        {:ok, issues} when is_list(issues) ->
          resume_revalidated_ci_terminal(state, Map.fetch!(state.running, issue_id), identifier, outcome, issue_id, issues)

        {:error, reason} ->
          Logger.warning("CI terminal wake revalidation failed: issue_id=#{issue_id} reason=#{inspect(reason)}")

          state

        other ->
          Logger.warning(
            "CI terminal wake revalidation returned unexpected value: " <>
              "issue_id=#{issue_id} value=#{inspect(other)}"
          )

          state
      end
    end)
  end

  defp resume_revalidated_ci_terminal(state, running_entry, identifier, outcome, issue_id, issues) do
    case Enum.find(issues, &match?(%Issue{id: ^issue_id}, &1)) do
      %Issue{} = issue ->
        state = Reconciler.refresh_running_entry_issue(state, issue, running_entry)
        refreshed_entry = Map.fetch!(state.running, issue_id)

        if terminal_handoff_state?(issue, outcome) do
          state
          |> cancel_ci_wait_rewake(issue_id)
          |> maybe_resume_ci_wait_runner(refreshed_entry, identifier)
        else
          state
        end

      nil ->
        state
    end
  end

  defp terminal_handoff_state?(%Issue{} = issue, :passed) do
    DispatchPolicy.issue_routable_to_worker?(issue) and
      not Issue.paused?(issue) and
      DispatchPolicy.normalize_issue_state(issue.state) == @active_handoff_state
  end

  defp terminal_handoff_state?(%Issue{} = issue, :failed) do
    DispatchPolicy.issue_routable_to_worker?(issue) and
      not Issue.paused?(issue) and
      DispatchPolicy.normalize_issue_state(issue.state) == "rework"
  end

  defp resume_ci_wait_runner(state, running_entry, identifier) do
    case PauseResume.resume_paused_issue(state, running_entry, false) do
      {{:ok, :resumed}, next_state} ->
        next_state

      {{:error, reason}, next_state} ->
        Logger.warning("CI terminal auto-resume deferred: issue_identifier=#{identifier} reason=#{inspect(reason)}")
        next_state
    end
  end

  defp ci_wait_rewakes(%State{} = state), do: Map.get(state.ci_lifecycle, :rewakes, %{})

  defp put_ci_wait_rewakes(%State{} = state, rewakes) when is_map(rewakes) do
    %{state | ci_lifecycle: Map.put(state.ci_lifecycle, :rewakes, rewakes)}
  end

  defp fetch_ci_wait_issue({issue_fetcher, issue_id}) do
    issue_fetcher.([issue_id])
  end

  defp apply_ci_wait_revalidation(state, response, {issue_id}) do
    case response do
      {:ok, issues} when is_list(issues) ->
        case Enum.find(issues, &match?(%Issue{id: ^issue_id}, &1)) do
          %Issue{} = issue -> maybe_rewake_current_ci_wait(state, issue)
          nil -> state
        end

      {:error, reason} ->
        Logger.warning("CI wait fallback revalidation failed: issue_id=#{issue_id} reason=#{inspect(reason)}")

        rearm_ci_wait_rewake(state, issue_id)

      other ->
        Logger.warning(
          "CI wait fallback revalidation returned unexpected value: " <>
            "issue_id=#{issue_id} value=#{inspect(other)}"
        )

        rearm_ci_wait_rewake(state, issue_id)
    end
  end

  defp write_ci_wait_fallback_state({issue}) do
    TicketTransition.write_state(
      to_string(issue.id || issue.identifier),
      @active_handoff_state,
      Keyword.put(Transition.expected_state_opts(issue), :writer, :ci_lifecycle)
    )
  end

  defp apply_ci_wait_fallback_transition(
         state,
         response,
         {issue}
       ) do
    case response do
      :ok ->
        active_issue = %{issue | state: @active_handoff_state}

        state
        |> Reconciler.refresh_running_issue_state(active_issue)
        |> enqueue_ci_wait_rewake_handoff(active_issue)
        |> maybe_reactivate_after_ci_wait_fallback(active_issue)

      {:error, reason} ->
        Logger.warning(
          "CI wait fallback transition failed: #{State.issue_context(issue)} " <>
            "reason=#{inspect(reason)}"
        )

        arm_ci_wait_rewake(state, issue)
    end
  end
end
