defmodule Aiur.Orchestrator.BlockerMergeWakeTest do
  @moduledoc """
  A declared blocker's merged pull request must wake the blocked agent.

  `aiur_declare_blocker(N)` binds the blockee to `ticket.N.pr.merged`, and the
  binding does deliver: the blockee's `Aiur.Events.SubscriptionStore` receives
  the Exchange fan-out and enqueues an events digest. What decides whether that
  digest actually *reaches* an agent sitting inside a live turn waiting on the
  blocker is `Aiur.Orchestrator.AutoSubscriptions.blocker_critical_digest?/2`.
  A digest it rejects is queued without an interrupt, and the mid-turn
  safe-checkpoint drain (`claim_blocker_critical_events_digest`) never claims
  it — so it lands only at the next turn boundary, which a waiting agent never
  reaches.

  Every test here runs the blockee with a live turn registered in
  `Aiur.Opencode.ActiveTurns`, because that is the stranded agent's real
  situation: an idle or sleeping agent is woken by the generic queue-wake path
  regardless of blocker classification, and would hide the defect.

  These tests pin both halves of the reported asymmetry: the wake must arrive
  when the Executor merges the blocker's pull request, exactly as it already
  does when the blocker's own agent emits `agent.unblocked`.
  """

  use ExUnit.Case, async: true

  alias Aiur.AgentQueueStore
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Issue
  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator.AutoSubscriptions
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.State
  alias Aiur.TestSupport

  setup do
    blockee = "blockee-#{System.unique_integer([:positive])}"
    turn_id = "turn-#{System.unique_integer([:positive])}"
    :ok = ActiveTurns.put(blockee, turn_id)
    on_exit(fn -> ActiveTurns.mark_closed(blockee, turn_id, :test_cleanup) end)

    {:ok, blockee: blockee, blocker: "blocker-#{System.unique_integer([:positive])}"}
  end

  defp base_state do
    %State{
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      queue_store: AgentQueueStore.new(),
      last_polled_issues: %{},
      todo_over_capacity_alert_active: false,
      agent_totals: nil,
      agent_rate_limits: nil,
      codex_totals: nil,
      codex_rate_limits: nil,
      poll_interval_ms: 60_000,
      max_concurrent_agents: nil,
      session_max_concurrent_agents: nil,
      effective_concurrent_agents: nil,
      load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: nil},
      next_poll_due_at_ms: nil,
      poll_check_in_progress: nil,
      tick_timer_ref: nil,
      tick_token: nil,
      initial_dispatch_cycle: false,
      events_etag: nil,
      events_last_id: nil,
      github_comments_since: %{},
      github_comment_issue_updated_at: %{},
      github_connectivity: %{},
      github_poll_delays: %{},
      github_command_scan_since: nil
    }
  end

  # A blockee inside a live turn, with `blocker_identifiers` declared on it
  # exactly as the poll hydrates a declared dependency.
  defp blocked_state(blockee, blocker_identifiers) do
    blocked_by =
      Enum.map(blocker_identifiers, fn identifier ->
        %{id: "issue-#{identifier}", identifier: identifier, state: "in-progress"}
      end)

    issue = %Issue{
      id: "issue-#{blockee}",
      identifier: blockee,
      state: "in-progress",
      blocked_by: blocked_by
    }

    entry = %{
      identifier: blockee,
      pid: self(),
      issue: issue,
      control: %{status: :working, can_interrupt: true}
    }

    %{base_state() | running: %{issue.id => entry}, last_polled_issues: %{issue.id => issue}}
  end

  defp enqueue(state, blockee, topic) do
    event = %{id: System.unique_integer([:positive]), topic: topic}
    {:reply, :ok, next} = OperatorMessages.enqueue_event_digest_call(state, blockee, event)
    next
  end

  defp queued_items(state) do
    state.queue_store.items |> Map.values() |> Enum.sort_by(& &1.id)
  end

  defp claim_blocker_critical(state, blockee) do
    {:reply, reply, next} = OperatorMessages.claim_blocker_critical_events_digest_call(state, blockee)
    {reply, next}
  end

  describe "a declared blocker's merged pull request" do
    test "wakes the blocked agent mid-turn with no operator action", context do
      %{blockee: blockee, blocker: blocker} = context
      state = blocked_state(blockee, [blocker])

      state = enqueue(state, blockee, "ticket.#{blocker}.pr.merged")

      [item] = queued_items(state)

      # The digest is urgent, so it interrupts the live turn rather than
      # waiting for a turn boundary the parked agent never reaches.
      assert item.body.urgent == true
      assert item.delivery.interrupt_requested == true
      assert item.delivery.priority == :now

      # And the running agent is told to take it now.
      assert_receive {:agent_queue_updated, ^blockee, _id, true}

      # The mid-turn safe-checkpoint drain claims it — this is the wake.
      assert {{:ok, claimed}, _state} = claim_blocker_critical(state, blockee)
      assert claimed.id == item.id
    end

    test "wakes the blockee whether the Executor merges the PR or the blocker's own agent releases it",
         context do
      # The reported trigger is the asymmetry: `agent.unblocked` (emitted by the
      # blocker's own agent) already woke the blockee, while the Executor
      # merging the blocker's PR did not. Both must wake it.
      %{blockee: blockee, blocker: blocker} = context

      for topic <- ["ticket.#{blocker}.pr.merged", "ticket.#{blocker}.agent.unblocked"] do
        state = blockee |> blocked_state([blocker]) |> enqueue(blockee, topic)

        [item] = queued_items(state)

        assert item.body.urgent == true, "#{topic} did not produce an urgent digest"
        assert item.delivery.interrupt_requested == true, "#{topic} did not interrupt the live turn"
        assert {{:ok, _claimed}, _next} = claim_blocker_critical(state, blockee)
      end
    end

    test "a merged pull request on a ticket that does not block the agent never wakes it", context do
      %{blockee: blockee, blocker: blocker} = context
      state = blocked_state(blockee, [blocker])

      state = enqueue(state, blockee, "ticket.not-a-blocker-9999.pr.merged")

      [item] = queued_items(state)

      refute item.body.urgent
      refute item.delivery.interrupt_requested
      assert {:empty, _state} = claim_blocker_critical(state, blockee)
    end

    test "many bindings across several blockers produce one wake per merged blocker", context do
      # One ticket in the reported run carried 18 blocker bindings across 3
      # blockers. Fan-out is bounded by the blockers themselves, not by the
      # bindings: merging one blocker's PR yields exactly one urgent digest,
      # claimable exactly once.
      %{blockee: blockee} = context
      blockers = Enum.map(1..3, fn n -> "blocker-#{System.unique_integer([:positive])}-#{n}" end)
      state = blocked_state(blockee, blockers)

      state = Enum.reduce(blockers, state, &enqueue(&2, blockee, "ticket.#{&1}.pr.merged"))

      items = queued_items(state)
      assert length(items) == 3
      assert Enum.all?(items, & &1.body.urgent)

      state =
        Enum.reduce(blockers, state, fn _blocker, acc ->
          assert {{:ok, _item}, next} = claim_blocker_critical(acc, blockee)
          next
        end)

      assert {:empty, _state} = claim_blocker_critical(state, blockee)
    end
  end

  describe "on a tracker whose poll never carries the dependency" do
    # GitHub's issue list poll never populates `blocked_by`, and neither of the
    # two places that hydrate it writes the hydrated issue back into
    # `last_polled_issues`. The blocker set must therefore also be readable
    # from the durable subscription bindings that `aiur_declare_blocker` wrote.
    setup do
      :ok = TestSupport.ensure_subscription_store_supervisor_running()
    end

    test "a declared blocker read from the subscription bindings still wakes the agent", context do
      %{blockee: blockee, blocker: blocker} = context
      :ok = AutoSubscriptions.subscribe_for_declared_blocker(blockee, blocker)
      on_exit(fn -> SubscriptionStore.stop(blockee) end)
      on_exit(fn -> SubscriptionStore.stop(blocker) end)

      # The polled issue knows nothing about the dependency — the GitHub shape.
      state = blocked_state(blockee, [])
      assert AutoSubscriptions.direct_blockers_for(state, blockee) == [blocker]

      state = enqueue(state, blockee, "ticket.#{blocker}.pr.merged")

      [item] = queued_items(state)
      assert item.body.urgent == true
      assert item.delivery.interrupt_requested == true
      assert {{:ok, _claimed}, _next} = claim_blocker_critical(state, blockee)
    end

    test "a sibling an agent chose to watch is not a blocker and never interrupts", context do
      %{blockee: blockee} = context
      sibling = "sibling-#{System.unique_integer([:positive])}"
      :ok = SubscriptionStore.attach(blockee)
      on_exit(fn -> SubscriptionStore.stop(blockee) end)

      :ok =
        SubscriptionStore.add_subscription(
          blockee,
          "ticket.#{sibling}.pr.merged",
          "manual:agent"
        )

      state = blocked_state(blockee, [])
      refute sibling in AutoSubscriptions.direct_blockers_for(state, blockee)

      state = enqueue(state, blockee, "ticket.#{sibling}.pr.merged")

      [item] = queued_items(state)
      refute item.body.urgent
      refute item.delivery.interrupt_requested
      assert {:empty, _state} = claim_blocker_critical(state, blockee)
    end

    test "an unavailable subscription store degrades to the polled blockers", context do
      # No store is attached for this blockee: the snapshot answers `:not_found`
      # and the polled set still stands, so behaviour is exactly what it was
      # before the bindings were consulted — never an exception, never worse.
      %{blockee: blockee, blocker: blocker} = context
      state = blocked_state(blockee, [blocker])

      assert AutoSubscriptions.direct_blockers_for(state, blockee) == [blocker]
      assert AutoSubscriptions.direct_blockers_for(blocked_state(blockee, []), blockee) == []
    end
  end
end
