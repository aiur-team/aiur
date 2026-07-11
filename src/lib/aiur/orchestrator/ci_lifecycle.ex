defmodule Aiur.Orchestrator.CiLifecycle do
  @moduledoc """
  Coordinates tracker transitions, runner control, and terminal events for CI.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.{CIApprovalStore, Issue, Tracker}
  alias Aiur.Events.{Publisher, Sanitizer}

  alias Aiur.Orchestrator.{
    DispatchPolicy,
    PauseResume,
    Reconciler,
    RetryEngine,
    State
  }

  @ci_failure_excerpt_message_max 1_200
  @ci_wait_state "ci-wait"

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

        PauseResume.transition_control_status(state, running_entry, :paused, "ci_wait")

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
      {:ok, _id, _subscribers} ->
        state

      :deduped ->
        state

      :filtered ->
        Logger.warning("CI terminal event unexpectedly filtered: issue=#{target} topic=#{topic}")
        state
    end
  end

  defp ci_wait_state?(state_name) do
    DispatchPolicy.normalize_issue_state(state_name) == @ci_wait_state
  end

  defp ci_event_dedup_key(target, outcome, head_sha)
       when is_binary(target) and is_atom(outcome) and is_binary(head_sha) do
    {"ci", Atom.to_string(outcome), target <> ":" <> head_sha}
  end

  defp ci_event_dedup_key(_target, _outcome, _head_sha), do: nil

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
