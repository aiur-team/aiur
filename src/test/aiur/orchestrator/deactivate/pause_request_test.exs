defmodule Aiur.Orchestrator.Deactivate.PauseRequestTest do
  use Aiur.TestSupport

  alias Aiur.Events.SubscriptionStore
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{EventTopics, PushRouting}

  describe "pause-request topic parser (subscriber wiring)" do
    test "extracts the identifier from a valid agent.pause.request topic" do
      assert {:ok, "100"} =
               EventTopics.parse_pause_request_topic("ticket.100.agent.pause.request")

      assert {:ok, "ABC-42"} =
               EventTopics.parse_pause_request_topic("ticket.ABC-42.agent.pause.request")
    end

    test "rejects unrelated topics" do
      for unrelated <- [
            "ticket.100.agent.pause",
            "ticket.100.agent.pause.requested",
            "ticket.100.pr.review_comment",
            "system.main.branch.push"
          ] do
        assert :nomatch = EventTopics.parse_pause_request_topic(unrelated)
      end
    end
  end

  describe "agent.pause.request awaits worker evidence" do
    test "running entry stays working until the worker confirms its pause" do
      issue_id = "issue-pause-1"
      identifier = "PAUSE-1"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = PushRouting.maybe_pause_on_request(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :working
    end

    test "no-op when entry is already paused" do
      issue_id = "issue-pause-2"
      identifier = "PAUSE-2"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :paused}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert ^state = PushRouting.maybe_pause_on_request(state, identifier)
    end

    test "no-op when entry is :deactivated (don't bring back from the dead)" do
      issue_id = "issue-pause-3"
      identifier = "PAUSE-3"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "human-review", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :deactivated}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = PushRouting.maybe_pause_on_request(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :deactivated
    end

    test "no-op when identifier isn't running" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert ^state = PushRouting.maybe_pause_on_request(state, "UNKNOWN")
    end

    test "does not stamp paused_at before the worker confirms the pause" do
      issue_id = "issue-pause-clock"
      identifier = "PAUSE-CLOCK"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.add(DateTime.utc_now(), -120, :second),
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = PushRouting.maybe_pause_on_request(state, identifier)
      entry = next.running[issue_id]

      assert entry.control.status == :working
      refute Map.has_key?(entry, :paused_at)
    end
  end

  describe "subscribe_for_declared_blocker/2 (called from agent_runner on declare)" do
    test "blockee gets unblock readiness and branch-ref subscriptions immediately" do
      blockee = "BSDB-blockee-#{System.unique_integer([:positive])}"
      blocker = "BSDB-blocker-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        :ok = SubscriptionStore.stop(blockee)
        :ok = SubscriptionStore.stop(blocker)
      end)

      :ok = Orchestrator.subscribe_for_declared_blocker(blockee, blocker)

      %{subscribed_to: subs} = SubscriptionStore.snapshot(blockee)

      topics = Enum.map(subs, fn entry -> entry["topic"] || entry[:topic] end)

      assert "ticket.#{blocker}.agent.unblocked" in topics,
             "blockee must subscribe to explicit unblock readiness"

      assert "ticket.#{blocker}.branch.push" in topics,
             "blockee must retain the blocker branch ref for fetch and inspection"
    end

    test "second call is idempotent (no duplicate subscriptions)" do
      blockee = "BSDB-idem-blockee-#{System.unique_integer([:positive])}"
      blocker = "BSDB-idem-blocker-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        :ok = SubscriptionStore.stop(blockee)
        :ok = SubscriptionStore.stop(blocker)
      end)

      :ok = Orchestrator.subscribe_for_declared_blocker(blockee, blocker)
      :ok = Orchestrator.subscribe_for_declared_blocker(blockee, blocker)

      %{subscribed_to: subs} = SubscriptionStore.snapshot(blockee)

      push_subs =
        Enum.filter(subs, fn e ->
          (e["topic"] || e[:topic]) == "ticket.#{blocker}.branch.push"
        end)

      assert length(push_subs) == 1
    end

    test "accepts integer identifiers (the GitHub API path)" do
      blockee = "BSDB-int-#{System.unique_integer([:positive])}"
      blocker_int = System.unique_integer([:positive])

      on_exit(fn ->
        :ok = SubscriptionStore.stop(blockee)
        :ok = SubscriptionStore.stop(to_string(blocker_int))
      end)

      :ok = Orchestrator.subscribe_for_declared_blocker(blockee, blocker_int)

      %{subscribed_to: subs} = SubscriptionStore.snapshot(blockee)
      topics = Enum.map(subs, fn e -> e["topic"] || e[:topic] end)

      assert "ticket.#{blocker_int}.branch.push" in topics
    end
  end
end
