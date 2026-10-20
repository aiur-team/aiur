defmodule Aiur.GitHub.Listeners.Comments.OutcomeOrderTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{CommentPollingState, ReadyForReviewTransitions, State, TrackerHealth}

  test "outcome folds connectivity then review-seen then draft observations" do
    parent = self()
    state = %State{github_poll_delays: %{comments: 10_000}, pr_review_seen_at: %{"42" => "old"}, pr_ready_ledger: %{}}
    outcome = %{connectivity: [:success], pr_review_seen_at: %{"42" => "new"}, pr_draft_observations: []}
    Code.ensure_loaded!(TrackerHealth)
    Code.ensure_loaded!(ReadyForReviewTransitions)
    health_call = {TrackerHealth, :note_github_connectivity_success, 2}
    draft_call = {ReadyForReviewTransitions, :observe, 3}
    :erlang.trace_pattern(health_call, true, [:local])
    :erlang.trace_pattern(draft_call, true, [:local])

    worker =
      spawn(fn ->
        receive do
          :fold -> send(parent, {:folded, self(), CommentPollingState.fold(state, outcome)})
        end
      end)

    on_exit(fn ->
      :erlang.trace_pattern(health_call, false, [:local])
      :erlang.trace_pattern(draft_call, false, [:local])
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    :erlang.trace(worker, true, [:call, {:tracer, self()}])
    send(worker, :fold)
    receive_barrier({:trace, ^worker, :call, {TrackerHealth, :note_github_connectivity_success, [health_input, :comments]}})
    receive_barrier({:trace, ^worker, :call, {ReadyForReviewTransitions, :observe, [draft_input, [], []]}})
    receive_barrier({:folded, ^worker, result})

    assert health_input.pr_review_seen_at == %{"42" => "old"}
    assert health_input.github_poll_delays == %{comments: 10_000}
    assert draft_input.pr_review_seen_at == %{"42" => "new"}
    assert draft_input.github_poll_delays == %{}
    assert result.pr_review_seen_at == %{"42" => "new"}
    assert result.github_poll_delays == %{}
    assert result.pr_ready_ledger == %{}
  end
end
