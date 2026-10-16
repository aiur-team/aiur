defmodule Aiur.Orchestrator.RetryEngine.HoldStreakTest do
  # Global event doubles require synchronous cases.
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.RetryEngine.HoldStreak
  alias Aiur.Orchestrator.State

  # Injected clock readings: the start of a hold, and a reading past the threshold.
  @t0 1_000
  @past @t0 + 30 * 60 * 1_000 + 1

  setup do
    Publisher.set_tracked_fn(fn _ -> true end)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    reset_at = DateTime.add(DateTime.utc_now(), 300, :second)
    {:ok, hold: %{reason: :broker_unavailable, resource: "core", reset_at: reset_at}}
  end

  describe "persistent local budget hold retries (#4693)" do
    test "a hold that never clears raises exactly one attention after the threshold", %{hold: hold} do
      {issue_id, identifier} = {"issue-never-clears", "repo#never-clears"}
      topic = HoldStreak.topic(identifier)
      :ok = Exchange.subscribe(topic)

      state = hold_retry(%State{}, issue_id, identifier, hold, @t0)
      refute_receive {:event, %{topic: ^topic}}, 50
      assert state.retry_attempts[issue_id].attempt == 1

      state = state |> hold_retry(issue_id, identifier, hold, @past) |> hold_retry(issue_id, identifier, hold, @past + 60_000)

      assert_receive {:event, %{topic: ^topic} = alert}, 1000
      assert alert["message"] =~ "reason=:broker_unavailable"
      assert alert["message"] =~ "reset_at=#{DateTime.to_iso8601(hold.reset_at)}"
      assert alert["message"] =~ "for 30 min (2 deferrals"
      refute_receive {:event, %{topic: ^topic}}, 50
      # Still non-consuming: the attempt never advanced while the hold persisted.
      assert state.retry_attempts[issue_id].attempt == 1
      assert state.budget_hold_streaks[issue_id].count == 3
      cancel(state, issue_id)
    end

    test "a hold that clears raises none", %{hold: hold} do
      {issue_id, identifier} = {"issue-clears", "repo#clears"}
      topic = HoldStreak.topic(identifier)
      :ok = Exchange.subscribe(topic)

      # The ticket dispatched before the next deferral, which would otherwise be past the threshold.
      state =
        %State{}
        |> hold_retry(issue_id, identifier, hold, @t0)
        |> RetryEngine.clear_budget_hold_streak(issue_id)
        |> hold_retry(issue_id, identifier, hold, @past)

      refute_receive {:event, %{topic: ^topic}}, 100
      assert state.budget_hold_streaks[issue_id].count == 1
      cancel(state, issue_id)
    end

    test "a non-hold retry ends the streak, so a later hold starts fresh", %{hold: hold} do
      {issue_id, identifier} = {"issue-lifts", "repo#lifts"}
      topic = HoldStreak.topic(identifier)
      :ok = Exchange.subscribe(topic)

      state = hold_retry(%State{}, issue_id, identifier, hold, @t0)
      cancel(state, issue_id)

      # The hold lifted and the attempt then waited for another reason.
      state = RetryEngine.schedule_issue_retry(state, issue_id, 1, %{identifier: identifier, delay_type: :capacity_wait, now_ms: @t0 + 1})
      refute Map.has_key?(state.budget_hold_streaks, issue_id)
      cancel(state, issue_id)

      state = hold_retry(state, issue_id, identifier, hold, @past)
      refute_receive {:event, %{topic: ^topic}}, 100
      assert state.budget_hold_streaks[issue_id].count == 1
      cancel(state, issue_id)
    end

    test "a committed dispatch resolves a raised attention", %{hold: hold} do
      {issue_id, identifier} = {"issue-resolves", "repo#resolves"}
      topic = HoldStreak.topic(identifier)
      resolved_topic = "#{topic}.resolved"
      :ok = Exchange.subscribe(topic)
      :ok = Exchange.subscribe(resolved_topic)

      state = %State{} |> hold_retry(issue_id, identifier, hold, @t0) |> hold_retry(issue_id, identifier, hold, @past)
      assert_receive {:event, %{topic: ^topic}}, 1000
      cancel(state, issue_id)

      assert {:noreply, dispatched} = Aiur.Orchestrator.handle_info({:dispatch_committed, issue_id}, state)

      assert_receive {:event, %{topic: ^resolved_topic}}, 1000
      refute Map.has_key?(dispatched.budget_hold_streaks, issue_id)
    end

    test "releasing the claim ends the run", %{hold: hold} do
      issue_id = "issue-released"
      state = hold_retry(%State{}, issue_id, "repo#released", hold, @t0)
      cancel(state, issue_id)

      refute Map.has_key?(RetryEngine.release_issue_claim(state, issue_id).budget_hold_streaks, issue_id)
    end
  end

  defp hold_retry(state, issue_id, identifier, hold, now_ms) do
    RetryEngine.schedule_issue_retry(state, issue_id, 1, %{identifier: identifier, delay_type: :local_budget_hold, local_budget_hold: hold, now_ms: now_ms})
  end

  defp cancel(state, issue_id), do: Process.cancel_timer(state.retry_attempts[issue_id].timer_ref)
end
