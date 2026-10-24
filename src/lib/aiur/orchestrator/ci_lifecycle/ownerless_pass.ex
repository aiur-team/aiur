defmodule Aiur.Orchestrator.CiLifecycle.OwnerlessPass do
  @moduledoc false

  alias Aiur.Events.GithubCIPoller
  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.CiLifecycle.Poll
  alias Aiur.Orchestrator.CiLifecycle.ResultProjection
  alias Aiur.Orchestrator.CiLifecycle.TerminalEvent
  alias Aiur.Orchestrator.CiLifecycle.Transition
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TicketTransition
  require Logger

  @human_review_state "human-review"

  @spec runtime_owned?(State.t(), Issue.t()) :: boolean()
  def runtime_owned?(state, issue) do
    case Map.get(state.running, issue.id) do
      %{identifier: identifier, control: %{status: status}, paused_reason: :ci_wait}
      when identifier == issue.identifier and status in [:paused, :deactivated] ->
        true

      _ ->
        false
    end
  end

  @spec transition_to_review(State.t(), Issue.t(), map(), (State.t(), Issue.t() -> State.t()), (State.t(), Issue.t(), map() -> State.t())) :: State.t()
  def transition_to_review(state, issue, result, clear_retry, remember_approved_head) do
    Poll.run_ci_effect(
      state,
      issue,
      "transition_ci_review",
      fn ->
        TicketTransition.write_state(
          to_string(issue.id || issue.identifier),
          @human_review_state,
          Keyword.put(Transition.expected_state_opts(issue), :writer, :ci_lifecycle)
        )
      end,
      fn current, response ->
        case response do
          :ok ->
            GithubCIPoller.record_pass(issue, result, result[:ci_recovery_opts] || [])
            review_issue = %{issue | state: @human_review_state}

            current
            |> then(&clear_retry.(&1, issue))
            |> then(&remember_approved_head.(&1, issue, result))
            |> Reconciler.refresh_running_issue_state(review_issue)
            |> ResultProjection.stash_last_ci_result(review_issue, result)
            |> TerminalEvent.ensure_ci_terminal_subscription(issue)
            |> TerminalEvent.publish_ci_terminal_event(issue, result, :passed)

          {:error, reason} ->
            Logger.warning("CI review handoff skipped: #{State.issue_context(issue)} reason=#{inspect(reason)}")
            current
        end
      end
    )
  end

  @spec ci_target_for_issue(Issue.t()) :: binary() | nil
  def ci_target_for_issue(issue), do: CiLifecycle.ci_target_for_issue(issue)
end
