defmodule Aiur.Orchestrator.CiLifecycle.Outcome do
  @moduledoc """
  Turns a CI poll result into the pass, failure, or stale-wait transition.
  """

  alias Aiur.Events.GithubCIPoller
  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.CiLifecycle.Poll
  alias Aiur.Orchestrator.CiLifecycle.ResultProjection
  alias Aiur.Orchestrator.CiLifecycle.TerminalEvent
  alias Aiur.Orchestrator.CiLifecycle.Transition
  alias Aiur.Orchestrator.CiLifecycle.WaitRewake
  alias Aiur.Orchestrator.HumanReview
  alias Aiur.Orchestrator.LifecycleFence
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.StartTrigger.ProgressStore
  require Logger

  @ci_wait_state "ci-wait"

  @human_review_state "human-review"

  @active_handoff_state "in-progress"

  defp apply_ci_poll_result(state, issue, %{decision: :pending} = result) do
    cond do
      CiLifecycle.ci_wait_state?(Transition.effective_ci_state(issue)) ->
        state

      HumanReview.human_review_state?(Transition.effective_ci_state(issue)) and result[:pending_reason] == :draft_pull_request ->
        Reconciler.refresh_running_issue_state(state, Transition.effective_issue_state(issue))

      HumanReview.human_review_state?(Transition.effective_ci_state(issue)) and ci_head_approved?(state, issue, result) ->
        Reconciler.refresh_running_issue_state(state, Transition.effective_issue_state(issue))

      true ->
        Transition.transition_ci_ticket(state, issue, @ci_wait_state)
    end
  end

  defp apply_ci_poll_result(state, issue, %{decision: :passed} = result) do
    if HumanReview.human_review_state?(Transition.effective_ci_state(issue)) do
      state
      |> clear_ci_test_failure_retry(issue)
      |> remember_ci_approved_head(issue, result)
      |> clear_stale_ci_wait(issue)
      |> Reconciler.refresh_running_issue_state(Transition.effective_issue_state(issue))
    else
      transition_ci_pass(state, issue, result)
    end
  end

  defp apply_ci_poll_result(state, issue, %{decision: :failed} = result) do
    cond do
      human_review_ci_replay?(state, issue, result) ->
        log_replayed_human_review_ci_failure(issue, result)

        state
        |> remember_ci_approved_head(issue, result)
        |> clear_stale_ci_wait(issue)
        |> Reconciler.refresh_running_issue_state(Transition.effective_issue_state(issue))

      retryable_test_failure?(state, issue, result) ->
        state
        |> remember_ci_test_failure_retry(issue, result)
        |> defer_ci_test_failure(issue)

      true ->
        state
        |> clear_ci_test_failure_retry(issue)
        |> transition_ci_failure(issue, result)
    end
  end

  defp apply_ci_poll_result(state, _issue, _result), do: state

  defp transition_ci_pass(state, issue, result) do
    if LifecycleFence.handoff_blocked?(state, issue) do
      Transition.log_fenced_ci_handoff(issue, @active_handoff_state)
      state
    else
      Poll.run_ci_effect(
        state,
        issue,
        "transition_ci_pass",
        fn -> write_ci_pass_state({issue, result}) end,
        fn arg1, arg2 ->
          apply_ci_pass_transition(arg1, arg2, {issue, result})
        end
      )
    end
  end

  defp transition_ci_failure(state, issue, result) do
    if LifecycleFence.handoff_blocked?(state, issue) do
      Transition.log_fenced_ci_handoff(issue, "rework")
      state
    else
      Poll.run_ci_effect(
        state,
        issue,
        "transition_ci_failure",
        fn -> write_ci_failure_state({issue, result}) end,
        fn arg1, arg2 -> apply_ci_failure_transition(arg1, arg2, {issue, result}) end
      )
    end
  end

  @doc false
  @spec recover_ci_poll_result(State.t(), term(), term(), term()) :: term()
  def recover_ci_poll_result(state, issue, result, opts) do
    result = Map.put(result, :ci_recovery_opts, opts)

    if CiLifecycle.ci_wait_state?(Transition.effective_ci_state(issue)) and
         (result[:decision] == :failed or result[:pending_reason] == :ci_cancelled or
            (result[:decision] == :pending and GithubCIPoller.attention_hold?(state.ci_lifecycle.poll_cache[CiLifecycle.ci_target_for_issue(issue)]))) and
         is_integer(result[:pr_number]) and not Issue.paused?(issue) and not LifecycleFence.handoff_blocked?(state, issue) do
      recovery = Keyword.get(opts, :ci_recovery, &GithubCIPoller.recover_failure/3)

      Poll.run_ci_effect(state, issue, "ci_recovery", fn -> recovery.(issue, result, opts) end, fn current, recovered ->
        recovered = GithubCIPoller.complete_recovery(issue, result, recovered, opts)
        current |> ResultProjection.stash_last_ci_result(issue, recovered) |> apply_ci_poll_result(issue, recovered)
      end)
    else
      apply_ci_poll_result(state, issue, result)
    end
  end

  defp retryable_test_failure?(_state, _issue, %{ci_recovery_checked: true}), do: false

  defp retryable_test_failure?(state, issue, %{head_sha: head_sha, failures: failures}) when is_binary(head_sha) and is_list(failures),
    do: failures != [] and Enum.all?(failures, &(&1.name == "test")) and Map.get(state.ci_lifecycle.test_failure_heads, CiLifecycle.ci_target_for_issue(issue)) != head_sha

  defp retryable_test_failure?(_state, _issue, _result), do: false

  defp defer_ci_test_failure(state, issue) do
    if HumanReview.human_review_state?(Transition.effective_ci_state(issue)) do
      Transition.transition_ci_ticket(state, issue, @ci_wait_state)
    else
      state
    end
  end

  # Retain the approved SHA across transient reruns; new heads re-enter CI.
  defp ci_head_approved?(%State{} = state, %Issue{} = issue, result) do
    case {Map.get(state.ci_lifecycle.approved_heads, CiLifecycle.ci_target_for_issue(issue)), Map.get(result, :head_sha)} do
      {approved_head, observed_head} when is_binary(approved_head) and approved_head == observed_head -> true
      {approved_head, nil} when is_binary(approved_head) -> true
      _ -> false
    end
  end

  # Legacy anchors also include operator-dismissed failures. Only a recorded CI
  # pass proves that a same-head failure in human-review is new repair work.
  defp human_review_ci_replay?(%State{} = state, %Issue{} = issue, result) do
    target = CiLifecycle.ci_target_for_issue(issue)
    approved_head = Map.get(state.ci_lifecycle.approved_heads, target)
    passed_head = state.ci_lifecycle |> Map.get(:passed_heads, %{}) |> Map.get(target)
    observed_head = Map.get(result, :head_sha)

    cond do
      Map.get(result, :draft?) == true ->
        false

      HumanReview.human_review_state?(Transition.effective_ci_state(issue)) ->
        is_nil(approved_head) or
          (ci_head_approved?(state, issue, result) and
             (is_nil(passed_head) or passed_head != observed_head))

      true ->
        ci_head_approved?(state, issue, result)
    end
  end

  # Held failures retain the reviewed head and failing checks so a red PR in review stays visible.
  defp log_replayed_human_review_ci_failure(%Issue{} = issue, result) do
    checks =
      result
      |> Map.get(:failures, [])
      |> Enum.map_join(", ", &Map.get(&1, :name, "unknown"))

    Logger.info(
      "CI failure held for reviewed head: #{State.issue_context(issue)} " <>
        "head=#{inspect(Map.get(result, :head_sha))} checks=#{inspect(checks)}"
    )
  end

  defp remember_ci_approved_head(%State{} = state, %Issue{} = issue, %{head_sha: head_sha} = result)
       when is_binary(head_sha) and head_sha != "" do
    case CiLifecycle.ci_target_for_issue(issue) do
      target when is_binary(target) ->
        approved_heads = Map.put(state.ci_lifecycle.approved_heads, target, head_sha)
        ci_lifecycle = Map.put(state.ci_lifecycle, :approved_heads, approved_heads)

        ci_lifecycle =
          if Map.get(result, :decision) == :passed do
            ProgressStore.record(target, %{pr_number: Map.get(result, :pr_number), stage: :pr_ci_green, head_sha: head_sha, source: :ci})
            Map.update(ci_lifecycle, :passed_heads, %{target => head_sha}, &Map.put(&1, target, head_sha))
          else
            ci_lifecycle
          end

        CiLifecycle.persist_ci_lifecycle_state(%{state | ci_lifecycle: ci_lifecycle})

      _ ->
        state
    end
  end

  defp remember_ci_approved_head(state, _issue, _result), do: state

  # Reassert the surviving disposition through the add-first owner; an approved head alone is not a label.
  defp clear_stale_ci_wait(%State{} = state, %Issue{} = issue) do
    if @ci_wait_state in List.wrap(issue.state_labels) and HumanReview.human_review_state?(Transition.effective_ci_state(issue)) do
      Poll.run_ci_effect(
        state,
        issue,
        :clear_stale_wait,
        fn -> reassert_human_review_state(issue) end,
        fn arg1, arg2 -> apply_stale_ci_wait_cleanup(arg1, arg2, {issue}) end
      )
    else
      state
    end
  end

  defp remember_ci_test_failure_retry(%State{} = state, %Issue{} = issue, %{head_sha: head_sha}) do
    case CiLifecycle.ci_target_for_issue(issue) do
      target when is_binary(target) and is_binary(head_sha) ->
        test_failure_heads = Map.put(state.ci_lifecycle.test_failure_heads, target, head_sha)
        ci_lifecycle = %{state.ci_lifecycle | test_failure_heads: test_failure_heads}
        CiLifecycle.persist_ci_lifecycle_state(%{state | ci_lifecycle: ci_lifecycle})

      _ ->
        state
    end
  end

  defp clear_ci_test_failure_retry(%State{} = state, %Issue{} = issue) do
    case CiLifecycle.ci_target_for_issue(issue) do
      target when is_binary(target) ->
        test_failure_heads = Map.delete(state.ci_lifecycle.test_failure_heads, target)
        ci_lifecycle = %{state.ci_lifecycle | test_failure_heads: test_failure_heads}
        CiLifecycle.persist_ci_lifecycle_state(%{state | ci_lifecycle: ci_lifecycle})

      _ ->
        state
    end
  end

  defp write_ci_pass_state({issue, result}) do
    response =
      TicketTransition.write_state(
        to_string(issue.id || issue.identifier),
        @active_handoff_state,
        Keyword.put(Transition.expected_state_opts(issue), :writer, :ci_lifecycle)
      )

    if response == :ok, do: GithubCIPoller.record_pass(issue, result, result[:ci_recovery_opts] || [])
    response
  end

  defp apply_ci_pass_transition(
         state,
         response,
         {issue, result}
       ) do
    case response do
      :ok ->
        active_issue = %{issue | state: @active_handoff_state}

        state
        |> clear_ci_test_failure_retry(issue)
        |> remember_ci_approved_head(issue, result)
        |> WaitRewake.cancel_ci_wait_rewake(issue.id)
        |> Reconciler.refresh_running_issue_state(active_issue)
        |> ResultProjection.stash_last_ci_result(active_issue, result)
        |> TerminalEvent.ensure_ci_terminal_subscription(issue)
        |> TerminalEvent.publish_ci_terminal_event(issue, result, :passed)

      {:error, reason} ->
        Logger.warning(
          "CI pass transition skipped: #{State.issue_context(issue)} " <>
            "reason=#{inspect(reason)}"
        )

        state
    end
  end

  defp write_ci_failure_state({issue, result}) do
    response =
      TicketTransition.write_state(
        to_string(issue.id || issue.identifier),
        "rework",
        Keyword.put(Transition.expected_state_opts(issue), :writer, :ci_lifecycle)
      )

    if response == :ok and result[:ci_recovery_checked], do: GithubCIPoller.record_failure(issue, result, result[:ci_recovery_opts])
    response
  end

  defp apply_ci_failure_transition(state, response, {issue, result}) do
    case response do
      :ok ->
        rework_issue = %{issue | state: "rework"}

        state
        |> clear_ci_test_failure_retry(issue)
        |> CiLifecycle.clear_ci_approved_head(issue)
        |> WaitRewake.cancel_ci_wait_rewake(issue.id)
        |> Reconciler.refresh_running_issue_state(rework_issue)
        |> ResultProjection.stash_last_ci_result(rework_issue, result)
        |> TerminalEvent.ensure_ci_terminal_subscription(issue)
        |> TerminalEvent.publish_ci_terminal_event(issue, result, :failed)

      {:error, reason} ->
        Logger.warning(
          "CI failure transition skipped: #{State.issue_context(issue)} " <>
            "reason=#{inspect(reason)}"
        )

        state
    end
  end

  defp reassert_human_review_state(issue) do
    TicketTransition.write_state(to_string(issue.id || issue.identifier), @human_review_state, Keyword.put(Transition.expected_state_opts(issue), :writer, :ci_lifecycle))
  end

  defp apply_stale_ci_wait_cleanup(state, response, {issue}) do
    case response do
      :ok ->
        state

      {:error, reason} ->
        Logger.warning("Stale ci-wait cleanup failed: #{State.issue_context(issue)} reason=#{inspect(reason)}")

        state
    end
  end
end
