defmodule Aiur.Orchestrator.CiLifecycle.ReviewHandoff do
  @moduledoc false

  alias Aiur.Orchestrator.CiLifecycle.Poll
  alias Aiur.Orchestrator.CiLifecycle.TerminalEvent
  alias Aiur.Orchestrator.CiLifecycle.Transition
  alias Aiur.Orchestrator.LifecycleFence
  alias Aiur.Orchestrator.ReadyForReviewTransitions
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TicketTransition
  require Logger

  @human_review_state "human-review"

  @spec ready_unreviewed_head?(map()) :: boolean()
  def ready_unreviewed_head?(%{draft?: false, reviewed_head?: false, pr_number: number, head_sha: sha})
      when is_integer(number) and is_binary(sha) and sha != "", do: true

  def ready_unreviewed_head?(_result), do: false

  @spec transition(State.t(), struct(), map()) :: State.t()
  def transition(state, issue, result) do
    if LifecycleFence.handoff_blocked?(state, issue) do
      Transition.log_fenced_ci_handoff(issue, @human_review_state)
      state
    else
      Poll.run_ci_effect(
        state,
        issue,
        "transition_ci_review",
        fn ->
          TicketTransition.write_state(
            to_string(issue.id || issue.identifier),
            @human_review_state,
            Transition.expected_state_opts(issue)
            |> Keyword.put(:writer, :ci_lifecycle)
            |> Keyword.put(:reason_modifiers, [])
          )
        end,
        fn current, response -> apply_transition(current, response, {issue, result}) end
      )
    end
  end

  @doc false
  @spec transition_stalled(State.t(), struct(), map(), (-> term())) :: State.t()
  def transition_stalled(state, issue, result, write_state) do
    case write_state.() do
      :ok ->
        apply_transition_success(state, issue, result)

      {:error, reason} ->
        Logger.warning("Stalled worker CI review handoff skipped: #{State.issue_context(issue)} reason=#{inspect(reason)}")
        state
    end
  end

  @doc false
  @spec apply_transition(State.t(), term(), {struct(), map()}) :: State.t()
  def apply_transition(current, :ok, {issue, result}), do: apply_transition_success(current, issue, result)

  def apply_transition(current, {:error, reason}, {issue, _result}) do
    Logger.warning("CI review handoff skipped: #{State.issue_context(issue)} reason=#{inspect(reason)}")
    current
  end

  defp apply_transition_success(current, issue, result) do
    review_issue = %{issue | state: @human_review_state}

    current
    |> ReadyForReviewTransitions.announce_ci_ready(to_string(issue.identifier || issue.id), result.pr_number, result.head_sha)
    |> Reconciler.refresh_running_issue_state(review_issue)
    |> TerminalEvent.ensure_ci_terminal_subscription(issue)
    |> TerminalEvent.publish_ci_terminal_event(issue, result, :passed)
  end
end
