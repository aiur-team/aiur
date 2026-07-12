defmodule Aiur.Orchestrator.CiLifecycle do
  @moduledoc """
  Coordinates tracker transitions, runner control, and terminal events for CI.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.{CIApprovalStore, Config, Issue, Tracker}
  alias Aiur.Events.{GithubCIPoller, IdGenerator, Publisher, Sanitizer, UniversalSubscriptions}

  alias Aiur.Orchestrator.{
    DispatchPolicy,
    HumanReview,
    OperatorMessages,
    PauseResume,
    Reconciler,
    RetryEngine,
    State,
    TrackerHealth
  }

  @ci_failure_excerpt_message_max 1_200
  @ci_wait_state "ci-wait"
  @human_review_state "human-review"
  @active_handoff_state "in-progress"
  @ci_poll_states [@ci_wait_state, @human_review_state]

  @spec poll_github_ci(State.t(), keyword()) :: State.t()
  def poll_github_ci(%State{} = state, opts \\ []) do
    case Config.tracker_kind() do
      "github" -> do_poll_github_ci(state, opts)
      _ -> state
    end
  end

  @spec maybe_resume_for_ci_failure(State.t(), String.t()) :: State.t()
  def maybe_resume_for_ci_failure(%State{} = state, identifier) when is_binary(identifier) do
    maybe_resume_for_ci_terminal(state, identifier, :failed)
  end

  @spec maybe_resume_for_ci_terminal(State.t(), String.t(), :passed | :failed) :: State.t()
  def maybe_resume_for_ci_terminal(%State{} = state, identifier, outcome)
      when is_binary(identifier) and outcome in [:passed, :failed] do
    case State.find_running_by_identifier(state.running, identifier) do
      %{control: %{status: :paused}, paused_reason: :ci_wait} = running_entry ->
        revalidate_ci_terminal_wake(
          state,
          running_entry,
          identifier,
          outcome,
          &Tracker.fetch_issue_states_by_ids/1
        )

      _ ->
        state
    end
  end

  @spec ci_wait_state?(term()) :: boolean()
  def ci_wait_state?(state_name) when is_binary(state_name) do
    DispatchPolicy.normalize_issue_state(state_name) == @ci_wait_state
  end

  def ci_wait_state?(_state_name), do: false

  @doc false
  @spec ci_target_for_issue(Issue.t() | term()) :: String.t() | nil
  def ci_target_for_issue(%Issue{identifier: identifier})
      when is_binary(identifier) and identifier != "",
      do: identifier

  def ci_target_for_issue(%Issue{id: id}) when is_binary(id) and id != "", do: id
  def ci_target_for_issue(_issue), do: nil

  @doc false
  @spec transition_ci_ticket(State.t(), Issue.t(), String.t()) :: State.t()
  def transition_ci_ticket(%State{} = state, %Issue{} = issue, next_state) do
    issue_key = issue.id || issue.identifier

    case Tracker.update_issue_state(to_string(issue_key), next_state) do
      :ok ->
        updated_issue = %{issue | state: next_state}

        state =
          if ci_wait_state?(next_state),
            do: clear_ci_approved_head(state, issue),
            else: state

        cond do
          DispatchPolicy.active_issue_state?(next_state, DispatchPolicy.active_state_set()) ->
            Reconciler.maybe_reactivate_or_refresh(state, updated_issue)

          ci_wait_state?(next_state) ->
            pause_issue_for_ci_wait(state, updated_issue)

          true ->
            Reconciler.refresh_running_issue_state(state, updated_issue)
        end

      {:error, reason} ->
        Logger.warning("CI lifecycle transition skipped: #{State.issue_context(issue)} state=#{next_state} reason=#{inspect(reason)}")

        state
    end
  end

  @doc false
  @spec pause_issue_for_ci_wait(State.t(), Issue.t()) :: State.t()
  def pause_issue_for_ci_wait(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      nil ->
        RetryEngine.release_issue_claim(state, issue.id)

      %{control: %{status: :deactivated}} = running_entry ->
        Reconciler.refresh_running_entry_issue(state, issue, running_entry)

      %{control: %{status: :paused}, paused_reason: :ci_wait} = running_entry ->
        state
        |> Reconciler.refresh_running_entry_issue(issue, running_entry)
        |> arm_ci_wait_rewake(issue)

      %{control: %{status: :paused}} = running_entry ->
        Reconciler.refresh_running_entry_issue(state, issue, running_entry)

      running_entry when is_map(running_entry) ->
        identifier = Map.get(running_entry, :identifier, issue.identifier || issue.id)

        Logger.info("CI wait detected: #{State.issue_context(issue)}; pausing active agent")

        _ = PauseResume.send_pause_control_message(state, identifier)

        running_entry =
          running_entry
          |> Map.put(:issue, issue)
          |> Map.put(:paused_reason, :ci_wait)

        state
        |> PauseResume.transition_control_status(running_entry, :paused, "ci_wait")
        |> arm_ci_wait_rewake(issue)

      _ ->
        state
    end
  end

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

  @doc false
  @spec clear_ci_approved_head(State.t(), Issue.t()) :: State.t()
  def clear_ci_approved_head(%State{} = state, %Issue{} = issue) do
    case ci_target_for_issue(issue) do
      target when is_binary(target) ->
        approved_heads = Map.delete(state.ci_lifecycle.approved_heads, target)

        persist_ci_lifecycle_state(%{
          state
          | ci_lifecycle: %{state.ci_lifecycle | approved_heads: approved_heads}
        })

      _ ->
        state
    end
  end

  @doc false
  @spec persist_ci_lifecycle_state(State.t()) :: State.t()
  def persist_ci_lifecycle_state(%State{} = state) do
    :ok =
      CIApprovalStore.save(
        state.ci_lifecycle.approved_heads,
        state.ci_lifecycle.test_failure_heads
      )

    state
  end

  @doc false
  @spec publish_ci_terminal_event(State.t(), Issue.t(), map(), :passed | :failed) :: State.t()
  def publish_ci_terminal_event(%State{} = state, %Issue{} = issue, result, outcome) do
    target = ci_target_for_issue(issue)
    topic = "ticket.#{target}.ci.#{outcome}"

    payload =
      %{
        source: :github,
        head_sha: Map.get(result, :head_sha),
        pr_number: Map.get(result, :pr_number),
        checks: Map.get(result, :failures, []),
        failure_excerpt: ci_failure_excerpt(Map.get(result, :failures, []))
      }
      |> Sanitizer.scrub()
      |> then(fn payload ->
        Map.put(
          payload,
          :message,
          ci_terminal_message(
            outcome,
            Map.get(payload, :checks, []),
            Map.get(payload, :failure_excerpt)
          )
        )
      end)

    case Publisher.publish(topic, payload,
           issue_number: target,
           bypass_contamination: true,
           dedup_key: ci_event_dedup_key(target, outcome, Map.get(result, :head_sha))
         ) do
      {:ok, id, _subscribers} ->
        event = Map.merge(payload, %{id: id, topic: topic})
        OperatorMessages.enqueue_event_digest_item(state, target, [event], event)

      :deduped ->
        state

      :filtered ->
        Logger.warning("CI terminal event unexpectedly filtered: issue=#{target} topic=#{topic}")
        state
    end
  end

  defp do_poll_github_ci(%State{} = state, opts) do
    issue_fetcher = Keyword.get(opts, :ci_issue_fetcher, &Tracker.fetch_issues_by_states/1)
    poller = Keyword.get(opts, :ci_poller, &GithubCIPoller.poll/2)

    case issue_fetcher.(@ci_poll_states) do
      {:ok, issues} when is_list(issues) ->
        state
        |> prune_ci_lifecycle_state(issues)
        |> poll_github_ci_targets(issues, poller, opts)

      {:error, reason} ->
        Logger.warning("GithubCIPoller target refresh skipped; reason=#{inspect(reason)}")
        TrackerHealth.note_github_connectivity_failure(state, :ci, reason)

      other ->
        Logger.warning("GithubCIPoller target refresh returned unexpected value=#{inspect(other)}")
        state
    end
  end

  defp poll_github_ci_targets(%State{} = state, issues, poller, opts) do
    issues_by_target = ci_issues_by_target(issues)
    targets = Map.keys(issues_by_target)

    case poller.(targets, opts) do
      {:ok, %{results: results, errors: errors}} when is_list(results) and is_list(errors) ->
        state =
          state
          |> note_ci_poll_connectivity(targets, errors)
          |> log_ci_poll_errors(errors)

        apply_ci_poll_results(state, results, issues_by_target)

      {:error, reason} ->
        Logger.warning("GithubCIPoller failed; reason=#{inspect(reason)}")
        TrackerHealth.note_github_connectivity_failure(state, :ci, reason)

      other ->
        Logger.warning("GithubCIPoller returned unexpected value=#{inspect(other)}")
        state
    end
  end

  defp ci_issues_by_target(issues) do
    Enum.reduce(issues, %{}, fn
      %Issue{} = issue, acc ->
        case ci_target_for_issue(issue) do
          nil -> acc
          target -> Map.put_new(acc, target, issue)
        end

      _other, acc ->
        acc
    end)
  end

  defp note_ci_poll_connectivity(state, targets, errors) do
    if errors == [] or not all_ci_targets_failed?(targets, errors) do
      TrackerHealth.note_github_connectivity_success(state, :ci)
    else
      TrackerHealth.note_github_connectivity_failure(state, :ci, List.first(errors))
    end
  end

  defp log_ci_poll_errors(state, []), do: state

  defp log_ci_poll_errors(state, errors) do
    Logger.warning("GithubCIPoller partial failures; reason=#{inspect(errors)}")
    state
  end

  defp apply_ci_poll_results(state, results, issues_by_target) do
    Enum.reduce(results, state, fn result, state_acc ->
      apply_ci_poll_result_for_target(state_acc, result, issues_by_target)
    end)
  end

  defp apply_ci_poll_result_for_target(state, result, issues_by_target) do
    case Map.get(issues_by_target, Map.get(result, :target)) do
      %Issue{} = issue -> apply_ci_poll_result(state, issue, result)
      _ -> state
    end
  end

  defp all_ci_targets_failed?([], _errors), do: false

  defp all_ci_targets_failed?(targets, errors) do
    failed_targets = errors |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    MapSet.subset?(MapSet.new(targets), failed_targets)
  end

  defp apply_ci_poll_result(state, issue, %{decision: :pending} = result) do
    cond do
      ci_wait_state?(issue.state) ->
        state

      HumanReview.human_review_state?(issue.state) and ci_head_approved?(state, issue, result) ->
        Reconciler.refresh_running_issue_state(state, issue)

      true ->
        transition_ci_ticket(state, issue, @ci_wait_state)
    end
  end

  defp apply_ci_poll_result(state, issue, %{decision: :passed} = result) do
    if HumanReview.human_review_state?(issue.state) do
      state
      |> clear_ci_test_failure_retry(issue)
      |> remember_ci_approved_head(issue, result)
      |> Reconciler.refresh_running_issue_state(issue)
    else
      transition_ci_pass(state, issue, result)
    end
  end

  defp apply_ci_poll_result(state, issue, %{decision: :failed} = result) do
    if retryable_test_failure?(state, issue, result) do
      state
      |> remember_ci_test_failure_retry(issue, result)
      |> defer_ci_test_failure(issue)
    else
      state
      |> clear_ci_test_failure_retry(issue)
      |> transition_ci_failure(issue, result)
    end
  end

  defp apply_ci_poll_result(state, _issue, _result), do: state

  defp transition_ci_pass(state, issue, result) do
    case Tracker.update_issue_state(to_string(issue.id || issue.identifier), @active_handoff_state) do
      :ok ->
        active_issue = %{issue | state: @active_handoff_state}

        state
        |> clear_ci_test_failure_retry(issue)
        |> remember_ci_approved_head(issue, result)
        |> cancel_ci_wait_rewake(issue.id)
        |> Reconciler.refresh_running_issue_state(active_issue)
        |> ensure_ci_terminal_subscription(issue)
        |> publish_ci_terminal_event(issue, result, :passed)

      {:error, reason} ->
        Logger.warning("CI pass transition skipped: #{State.issue_context(issue)} reason=#{inspect(reason)}")
        state
    end
  end

  defp transition_ci_failure(state, issue, result) do
    case Tracker.update_issue_state(to_string(issue.id || issue.identifier), "rework") do
      :ok ->
        rework_issue = %{issue | state: "rework"}

        state
        |> clear_ci_test_failure_retry(issue)
        |> clear_ci_approved_head(issue)
        |> cancel_ci_wait_rewake(issue.id)
        |> Reconciler.refresh_running_issue_state(rework_issue)
        |> ensure_ci_terminal_subscription(issue)
        |> publish_ci_terminal_event(issue, result, :failed)

      {:error, reason} ->
        Logger.warning("CI failure transition skipped: #{State.issue_context(issue)} reason=#{inspect(reason)}")
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

  # A failed `test` check may be the known seed-dependent flake. Defer only the
  # first terminal observation of that exact head for one regular poll cycle;
  # the second failure is delivered to the agent like every other CI failure.
  defp retryable_test_failure?(%State{} = state, %Issue{} = issue, %{head_sha: head_sha, failures: failures})
       when is_binary(head_sha) and is_list(failures) do
    test_only_failure?(failures) and
      Map.get(state.ci_lifecycle.test_failure_heads, ci_target_for_issue(issue)) != head_sha
  end

  defp retryable_test_failure?(_state, _issue, _result), do: false

  defp test_only_failure?(failures) do
    failures != [] and
      Enum.all?(failures, fn
        %{name: "test"} -> true
        _ -> false
      end)
  end

  defp defer_ci_test_failure(state, issue) do
    if HumanReview.human_review_state?(issue.state) do
      transition_ci_ticket(state, issue, @ci_wait_state)
    else
      state
    end
  end

  # A direct agent label flip is the initial CI handoff. Once a head has passed,
  # retain that exact SHA so a transient re-run does not pull it out of review;
  # a pending observation for a different SHA is a re-push and must re-enter the
  # CI gate.
  defp ci_head_approved?(%State{} = state, %Issue{} = issue, result) do
    case {Map.get(state.ci_lifecycle.approved_heads, ci_target_for_issue(issue)), Map.get(result, :head_sha)} do
      {approved_head, observed_head} when is_binary(approved_head) and approved_head == observed_head -> true
      {approved_head, nil} when is_binary(approved_head) -> true
      _ -> false
    end
  end

  defp remember_ci_approved_head(%State{} = state, %Issue{} = issue, %{head_sha: head_sha})
       when is_binary(head_sha) and head_sha != "" do
    case ci_target_for_issue(issue) do
      target when is_binary(target) ->
        approved_heads = Map.put(state.ci_lifecycle.approved_heads, target, head_sha)
        persist_ci_lifecycle_state(%{state | ci_lifecycle: %{state.ci_lifecycle | approved_heads: approved_heads}})

      _ ->
        state
    end
  end

  defp remember_ci_approved_head(state, _issue, _result), do: state

  defp remember_ci_test_failure_retry(%State{} = state, %Issue{} = issue, %{head_sha: head_sha}) do
    case ci_target_for_issue(issue) do
      target when is_binary(target) and is_binary(head_sha) ->
        test_failure_heads = Map.put(state.ci_lifecycle.test_failure_heads, target, head_sha)
        ci_lifecycle = %{state.ci_lifecycle | test_failure_heads: test_failure_heads}
        persist_ci_lifecycle_state(%{state | ci_lifecycle: ci_lifecycle})

      _ ->
        state
    end
  end

  defp clear_ci_test_failure_retry(%State{} = state, %Issue{} = issue) do
    case ci_target_for_issue(issue) do
      target when is_binary(target) ->
        test_failure_heads = Map.delete(state.ci_lifecycle.test_failure_heads, target)
        ci_lifecycle = %{state.ci_lifecycle | test_failure_heads: test_failure_heads}
        persist_ci_lifecycle_state(%{state | ci_lifecycle: ci_lifecycle})

      _ ->
        state
    end
  end

  defp prune_ci_lifecycle_state(%State{} = state, issues) do
    targets =
      issues
      |> Enum.map(&ci_target_for_issue/1)
      |> Enum.filter(&is_binary/1)

    approved_heads = Map.take(state.ci_lifecycle.approved_heads, targets)
    test_failure_heads = Map.take(state.ci_lifecycle.test_failure_heads, targets)

    if approved_heads == state.ci_lifecycle.approved_heads and
         test_failure_heads == state.ci_lifecycle.test_failure_heads do
      state
    else
      ci_lifecycle =
        state.ci_lifecycle
        |> Map.put(:approved_heads, approved_heads)
        |> Map.put(:test_failure_heads, test_failure_heads)

      persist_ci_lifecycle_state(%{state | ci_lifecycle: ci_lifecycle})
    end
  end

  defp ensure_ci_terminal_subscription(state, issue) do
    case ci_target_for_issue(issue) do
      target when is_binary(target) ->
        :ok = UniversalSubscriptions.attach(target)
        state

      _ ->
        state
    end
  end

  defp handle_current_ci_wait_rewake(state, issue_id, issue_fetcher) do
    case issue_fetcher.([issue_id]) do
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

  defp maybe_rewake_current_ci_wait(state, issue) do
    case Map.get(state.running, issue.id) do
      %{control: %{status: :paused}, paused_reason: :ci_wait} = running_entry ->
        cond do
          not ci_wait_state?(issue.state) ->
            state

          Issue.paused?(issue) ->
            Reconciler.refresh_running_entry_issue(state, issue, running_entry)

          not DispatchPolicy.issue_routable_to_worker?(issue) ->
            state

          true ->
            transition_ci_wait_fallback(state, issue)
        end

      _ ->
        state
    end
  end

  defp transition_ci_wait_fallback(state, issue) do
    case Tracker.update_issue_state(to_string(issue.id || issue.identifier), @active_handoff_state) do
      :ok ->
        active_issue = %{issue | state: @active_handoff_state}

        state
        |> Reconciler.refresh_running_issue_state(active_issue)
        |> enqueue_ci_wait_rewake_handoff(active_issue)
        |> maybe_reactivate_after_ci_wait_fallback(active_issue)

      {:error, reason} ->
        Logger.warning("CI wait fallback transition failed: #{State.issue_context(issue)} reason=#{inspect(reason)}")
        arm_ci_wait_rewake(state, issue)
    end
  end

  defp enqueue_ci_wait_rewake_handoff(state, issue) do
    identifier = issue.identifier || issue.id

    message =
      "No terminal CI event arrived before the fallback timeout. " <>
        "Check CI once; if it is still pending, return to agent:ci-wait without polling."

    event = %{
      id: IdGenerator.next_id(),
      topic: "ticket.#{identifier}.ci.rewake",
      source: :runtime,
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

      _ ->
        state
    end
  end

  defp maybe_resume_ci_wait_runner(state, running_entry, identifier) do
    if Issue.paused?(Map.get(running_entry, :issue)) do
      state
    else
      resume_ci_wait_runner(state, running_entry, identifier)
    end
  end

  defp revalidate_ci_terminal_wake(state, running_entry, identifier, outcome, issue_fetcher) do
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])

    case issue_fetcher.([issue_id]) do
      {:ok, issues} when is_list(issues) ->
        resume_revalidated_ci_terminal(state, running_entry, identifier, outcome, issue_id, issues)

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

  defp ci_event_dedup_key(target, outcome, head_sha)
       when is_binary(target) and is_atom(outcome) and is_binary(head_sha) do
    {"ci", Atom.to_string(outcome), target <> ":" <> head_sha}
  end

  defp ci_event_dedup_key(_target, _outcome, _head_sha), do: nil

  defp ci_wait_rewakes(%State{} = state), do: Map.get(state.ci_lifecycle, :rewakes, %{})

  defp put_ci_wait_rewakes(%State{} = state, rewakes) when is_map(rewakes) do
    %{state | ci_lifecycle: Map.put(state.ci_lifecycle, :rewakes, rewakes)}
  end

  defp ci_failure_excerpt(failures) when is_list(failures) do
    Enum.find_value(failures, fn
      %{excerpt: excerpt} when is_binary(excerpt) and excerpt != "" -> excerpt
      _ -> nil
    end)
  end

  defp ci_failure_excerpt(_failures), do: nil

  defp ci_terminal_message(:passed, _failures, _failure_excerpt),
    do: "CI passed for the current PR head"

  defp ci_terminal_message(:failed, failures, failure_excerpt) do
    names =
      failures
      |> Enum.map(&Map.get(&1, :name))
      |> Enum.filter(&is_binary/1)
      |> Enum.join(", ")

    message =
      if names == "", do: "CI failed for the current PR head", else: "CI failed: " <> names

    if is_binary(failure_excerpt) and failure_excerpt != "" do
      message <>
        ". Failure excerpt: " <>
        String.slice(failure_excerpt, 0, @ci_failure_excerpt_message_max)
    else
      message
    end
  end
end
