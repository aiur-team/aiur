defmodule Aiur.Orchestrator.ReworkDispatchClaim do
  @moduledoc false

  require Logger

  alias Aiur.{GitHub.Errors, Issue, Orchestrator.State}
  alias Aiur.Orchestrator.{DispatchPolicy, TicketTransition, TrackerTasks}

  @spec dispatch(State.t(), Issue.t(), (State.t() -> State.t()), (State.t(), atom() -> State.t()), (State.t(), String.t() -> term())) ::
          State.t()
  def dispatch(%State{} = state, %Issue{} = issue, dispatch_fun, decline_fun, input_fun) do
    if DispatchPolicy.normalize_issue_state(issue.state) == "rework" do
      claim_rework(state, issue, dispatch_fun, decline_fun, input_fun)
    else
      dispatch_fun.(state)
    end
  end

  defp claim_rework(state, issue, dispatch_fun, decline_fun, input_fun) do
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
      &apply_result(&1, &2, issue, expected_input, dispatch_fun, decline_fun, input_fun)
    )
  end

  defp apply_result(current, result, issue, expected_input, dispatch_fun, decline_fun, input_fun) do
    cond do
      input_fun.(current, issue.id) != expected_input ->
        current

      result == :ok ->
        dispatch_fun.(current)

      transient_hold?(result) ->
        # The guarded write never landed; release the claim so the next poll retries instead of declining.
        Logger.info("Rework dispatch claim held for #{State.issue_context(issue)}; retrying next poll: #{inspect(result)}")
        Map.update!(current, :claimed, &MapSet.delete(&1, issue.id))

      true ->
        Logger.warning("Rework dispatch claim failed for #{State.issue_context(issue)}: #{inspect(result)}")
        current |> Map.update!(:claimed, &MapSet.delete(&1, issue.id)) |> then(&decline_fun.(&1, :rework_claim_failed))
    end
  end

  defp transient_hold?({:error, {:github, kind, _detail}}) when kind in [:local_hold, :rate_limited], do: true
  defp transient_hold?({:error, reason}), do: match?({:github, :local_hold, _detail}, Errors.classify_transport(reason))
  defp transient_hold?(_result), do: false
end
