defmodule Aiur.Orchestrator.CiLifecycle.PrLessReview do
  @moduledoc """
  Holds a human-review ticket with no visible open PR in place of `ci-wait`.

  No CI run can resolve `ci-wait` for a ticket without an open PR, so moving it
  there strands it (#5816). A miss that persists across two polls raises one
  Executor attention; a visible PR or leaving human-review resolves it.
  """

  alias Aiur.Alerts
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.CiLifecycle.Transition
  alias Aiur.Orchestrator.HumanReview
  alias Aiur.Orchestrator.State
  require Logger

  @no_pr_reasons [:open_pr_not_yet_visible, :open_pr_no_longer_visible]

  @doc "True when the CI poll found no open PR for the ticket."
  @spec no_pull_request?(map()) :: boolean()
  def no_pull_request?(result), do: Map.get(result, :decision) == :pending and Map.get(result, :pending_reason) in @no_pr_reasons

  @doc false
  @spec reconcile(State.t(), Aiur.Issue.t(), map(), keyword()) :: State.t()
  def reconcile(%State{} = state, issue, result, opts) do
    target = CiLifecycle.ci_target_for_issue(issue)
    marks = Map.get(state.ci_lifecycle, :pr_less_review, %{})
    in_review? = HumanReview.human_review_state?(Transition.effective_ci_state(issue))

    cond do
      not is_binary(target) ->
        state

      in_review? and no_pull_request?(result) ->
        observe_miss(state, issue, target, Map.get(marks, target), opts)

      # A lookup failure proves nothing either way; keep the mark.
      in_review? and not is_integer(Map.get(result, :pr_number)) ->
        state

      Map.get(marks, target) == :alerted ->
        resolve(state, issue, target, opts)

      true ->
        put_mark(state, target, nil)
    end
  end

  @doc "Resolves the attention for a ticket that left the CI poll set (for example closed as done)."
  @spec resolve_departed(State.t(), [String.t()], keyword()) :: State.t()
  def resolve_departed(%State{} = state, targets, opts) do
    current = MapSet.new(targets)

    state.ci_lifecycle
    |> Map.get(:pr_less_review, %{})
    |> Enum.reject(fn {target, _mark} -> MapSet.member?(current, target) end)
    |> Enum.reduce(state, fn
      {target, :alerted}, acc -> resolve(acc, target, target, opts)
      {target, _mark}, acc -> put_mark(acc, target, nil)
    end)
  end

  # ponytail: marks are in-memory, so a restart can raise the attention once more.
  defp observe_miss(state, _issue, target, nil, _opts), do: put_mark(state, target, :seen)
  defp observe_miss(state, _issue, _target, :alerted, _opts), do: state

  defp observe_miss(state, issue, target, :seen, opts) do
    message =
      "Ticket #{target} is in human-review without an open pull request, so no CI or review can move it. " <>
        "Close it as done if its merged PRs cover the acceptance, or route it back to work."

    case emitter(opts).(topic(target), issue: issue, central: true, message: message, reason: message, needs_attention: true) do
      :ok -> put_mark(state, target, :alerted)
      {:error, reason} -> log_error(state, target, reason)
    end
  end

  defp resolve(state, issue, target, opts) do
    message = "Ticket #{target} is no longer in human-review without an open pull request."

    case emitter(opts).(topic(target) <> ".resolved", issue: issue, central: true, message: message, reason: message, needs_attention: false) do
      :ok -> put_mark(state, target, nil)
      {:error, reason} -> log_error(state, target, reason)
    end
  end

  defp topic(target), do: "ticket.#{target}.pr.human_review_without_pr"

  defp emitter(opts), do: Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2)

  defp put_mark(state, target, mark) do
    marks = Map.get(state.ci_lifecycle, :pr_less_review, %{})
    updated = if mark, do: Map.put(marks, target, mark), else: Map.delete(marks, target)

    if updated == marks,
      do: state,
      else: %{state | ci_lifecycle: Map.put(state.ci_lifecycle, :pr_less_review, updated)}
  end

  defp log_error(state, target, reason) do
    Logger.warning("Human-review-without-PR alert failed: issue=#{target} reason=#{inspect(reason)}")
    state
  end
end
