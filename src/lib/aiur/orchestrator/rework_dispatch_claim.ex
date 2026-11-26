defmodule Aiur.Orchestrator.ReworkDispatchClaim do
  @moduledoc false

  require Logger

  alias Aiur.{Issue, Orchestrator.State}
  alias Aiur.Orchestrator.{DispatchPolicy, RetryEngine, TicketTransition, TrackerTasks}
  alias Aiur.Orchestrator.RetryEngine.PollFailure

  @spec dispatch(
          State.t(),
          Issue.t(),
          integer() | nil,
          (State.t() -> State.t()),
          (State.t(), atom() -> State.t()),
          (State.t(), String.t() -> term())
        ) :: State.t()
  def dispatch(%State{} = state, %Issue{} = issue, attempt, dispatch_fun, decline_fun, input_fun) do
    if DispatchPolicy.normalize_issue_state(issue.state) == "rework" do
      claim_rework(state, {issue, attempt}, dispatch_fun, decline_fun, input_fun)
    else
      dispatch_fun.(state)
    end
  end

  defp claim_rework(state, {issue, _attempt} = target, dispatch_fun, decline_fun, input_fun) do
    claimed = %{state | claimed: MapSet.put(state.claimed, issue.id)}
    expected_input = input_fun.(claimed, issue.id)
    issue_key = to_string(issue.id || issue.identifier)

    TrackerTasks.run(
      claimed,
      {:rework_claim, issue.id},
      fn ->
        TicketTransition.write_state(issue_key, "in-progress",
          writer: :dispatcher,
          expected_state: issue.state,
          identifier: issue.identifier
        )
      end,
      &apply_result(&1, &2, target, expected_input, dispatch_fun, decline_fun, input_fun)
    )
  end

  defp apply_result(current, result, {issue, attempt}, expected_input, dispatch_fun, decline_fun, input_fun) do
    hold = transient_hold(result)

    cond do
      input_fun.(current, issue.id) != expected_input ->
        current

      result == :ok ->
        dispatch_fun.(current)

      is_map(hold) ->
        # The guarded write never landed; keep the claim and retry after the hold's reset_at instead of declining.
        Logger.info("Rework dispatch claim held for #{State.issue_context(issue)}; retrying after the hold: #{inspect(result)}")

        RetryEngine.schedule_issue_retry(current, issue.id, attempt, %{
          delay_type: :local_budget_hold,
          local_budget_hold: hold,
          error: "rework claim held: #{inspect(result)}",
          identifier: issue.identifier,
          tracker_identity: Issue.tracker_identity(issue),
          priority: issue.priority,
          issue_state: issue.state
        })

      true ->
        Logger.warning("Rework dispatch claim failed for #{State.issue_context(issue)}: #{inspect(result)}")
        current |> Map.update!(:claimed, &MapSet.delete(&1, issue.id)) |> then(&decline_fun.(&1, :rework_claim_failed))
    end
  end

  # The retry delay reads a DateTime `reset_at`; a rate limit carries GitHub's ISO-8601 reset.
  defp transient_hold({:error, {:github, :rate_limited, detail}}) when is_map(detail) do
    with reset when is_binary(reset) <- Map.get(detail, :reset_at),
         {:ok, reset_at, _offset} <- DateTime.from_iso8601(reset) do
      %{detail | reset_at: reset_at}
    else
      _ -> detail
    end
  end

  defp transient_hold({:error, reason}), do: PollFailure.local_budget_hold_reason(reason)
  defp transient_hold(_result), do: nil
end
