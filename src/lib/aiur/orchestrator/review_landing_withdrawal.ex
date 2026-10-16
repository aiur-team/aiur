defmodule Aiur.Orchestrator.ReviewLandingWithdrawal do
  @moduledoc """
  On a trusted `CHANGES_REQUESTED` review, takes the ticket's PR out of the merge
  queue and turns auto-merge off, then records both actions on the ticket (#4676).

  Routed from the `pr.review_comment` topic, which both the review webhook and
  the poll backstop publish, so either delivery path triggers it once.
  """

  require Logger

  alias Aiur.{Alerts, CodeHost, Tracker}
  alias Aiur.Orchestrator.{CommentWake, ReviewFreshness, ReworkGate, State, TrackerTasks}

  @spec changes_requested(State.t(), String.t(), map(), keyword()) :: State.t()
  def changes_requested(%State{} = state, identifier, event, opts \\ []) do
    # A stale or since-approved review must not pull an approved PR back out of the queue.
    if changes_requested_review?(event) and CommentWake.trusted_comment_event?(event) and is_nil(ReviewFreshness.rework_skip_reason(event)) do
      TrackerTasks.run(state, {:landing_withdrawal, identifier, make_ref()}, fn -> withdraw(to_string(identifier), opts) end, fn current, _result -> current end)
    else
      state
    end
  end

  defp withdraw(identifier, opts) do
    withdraw_fun = Keyword.get(opts, :withdraw, &CodeHost.withdraw_landing/1)

    case ReworkGate.open_pr(identifier, opts) do
      {:ok, %{"number" => number}} when is_integer(number) -> record(identifier, number, withdraw_fun.(number), opts)
      _no_pr -> :ok
    end
  end

  defp record(_identifier, _number, {:ok, []}, _opts), do: :ok
  defp record(_identifier, _number, {:error, :code_host_unavailable}, _opts), do: :ok
  defp record(identifier, number, {:error, reason}, opts), do: record(identifier, number, {:error, reason, []}, opts)

  defp record(identifier, number, {:ok, actions}, opts), do: comment(identifier, number, actions, opts)

  defp record(identifier, number, {:error, reason, actions}, opts) do
    if actions != [], do: comment(identifier, number, actions, opts)
    Logger.warning("landing withdrawal failed issue_identifier=#{identifier} pr=#{number} reason=#{inspect(reason)}")

    Keyword.get(opts, :emit_alert, &Alerts.emit_system/2).(
      "ticket.#{identifier}.agent.attention.landing_withdrawal_failed",
      issue: identifier,
      message: "PR ##{number} got CHANGES_REQUESTED but Aiur could not take it out of the merge queue (#{inspect(reason)})",
      reason: "A rejected PR keeps its merge-queue slot. Remedy: dequeue it and turn auto-merge off by hand.",
      needs_attention: true,
      severity: "warning"
    )
  end

  defp comment(identifier, number, actions, opts) do
    done = Enum.map_join(actions, " and ", &action_text/1)
    body = "After a CHANGES_REQUESTED review on PR ##{number}, Aiur #{done}. A later Executor approval lands it through the normal merge path."
    Keyword.get(opts, :create_comment, &Tracker.create_comment/2).(identifier, body)
  end

  defp action_text(:dequeued), do: "removed it from the merge queue"
  defp action_text(:auto_merge_disabled), do: "turned auto-merge off"

  # Both publishers put the review under `comment` with an upper-cased `state`;
  # atom keys come from an in-process publish, string keys after a JSON round trip.
  defp changes_requested_review?(event) do
    comment = Map.get(event, :comment) || Map.get(event, "comment")
    is_map(comment) and (Map.get(comment, :state) || Map.get(comment, "state")) == "CHANGES_REQUESTED"
  end
end
