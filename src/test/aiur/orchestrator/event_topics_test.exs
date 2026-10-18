defmodule Aiur.Orchestrator.EventTopicsTest do
  use ExUnit.Case, async: false

  alias Aiur.DecisionStore
  alias Aiur.Orchestrator.{EventTopics, Lifecycle, PushRouting, State}

  test "a branch push raises one attention when the live PR Tested head is stale" do
    identifier = "4611"
    pushed_sha = String.duplicate("a", 40)
    emitted = :atomics.new(1, [])

    pr_fetch = fn number ->
      assert number == String.to_integer(identifier)

      {:ok,
       %{
         "number" => number + 1000,
         "head" => %{"sha" => pushed_sha},
         "body" => "Tested head: #{String.duplicate("b", 40)}"
       }}
    end

    emitter = fn topic, opts ->
      assert topic == "ticket.#{identifier}.pr.tested_head_stale"
      assert opts[:needs_attention]
      assert opts[:message] =~ "PR ##{identifier |> String.to_integer() |> Kernel.+(1000)}"
      assert opts[:reason] =~ "Refresh the PR body's Tested head"
      :atomics.add_get(emitted, 1, 1)
      :ok
    end

    state = %State{}
    event = %{topic: "ticket.#{identifier}.branch.push", sha: pushed_sha}
    condition = :atomics.new(1, [])
    condition_state = fn _ -> if :atomics.get(condition, 1) == 1, do: :firing, else: :unknown end

    assert {:branch_push, ^identifier} = EventTopics.classify_event_topic(event.topic)

    assert :atomics.get(emitted, 1) == 0

    assert {:ok, _pr} = pr_fetch.(String.to_integer(identifier))

    EventTopics.route(state, event,
      pull_request_fetcher: pr_fetch,
      alert_emitter: emitter,
      condition_state: condition_state
    )

    assert :atomics.get(emitted, 1) == 1
    :atomics.put(condition, 1, 1)

    EventTopics.route(state, event,
      pull_request_fetcher: pr_fetch,
      alert_emitter: emitter,
      condition_state: condition_state
    )

    assert :atomics.get(emitted, 1) == 1
  end

  test "a branch push does not alert when the PR body already names its head" do
    identifier = Integer.to_string(System.unique_integer([:positive]))
    pushed_sha = String.duplicate("c", 40)

    pr_fetch = fn number ->
      {:ok,
       %{
         "number" => number,
         "head" => %{"sha" => pushed_sha},
         "body" => "Tested head: #{pushed_sha}"
       }}
    end

    emitter = fn _topic, _opts -> flunk("matching evidence must not raise attention") end

    state = %State{}
    event = %{topic: "ticket.#{identifier}.branch.push", sha: pushed_sha}

    PushRouting.check_pr_body_head(state, identifier, event,
      pull_request_fetcher: pr_fetch,
      alert_emitter: emitter
    )

    PushRouting.check_pr_body_head(state, identifier, event,
      pull_request_fetcher: pr_fetch,
      alert_emitter: emitter
    )
  end

  test "an older queued branch push still alerts when the live PR body is stale" do
    identifier = Integer.to_string(System.unique_integer([:positive]))
    pushed_sha = String.duplicate("d", 40)
    live_head_sha = String.duplicate("e", 40)
    emitted = :atomics.new(1, [])

    pr_fetch = fn _number ->
      {:ok,
       %{
         "number" => 9001,
         "head" => %{"sha" => live_head_sha},
         "body" => "Tested head: #{String.duplicate("f", 40)}"
       }}
    end

    emitter = fn topic, opts ->
      assert topic == "ticket.#{identifier}.pr.tested_head_stale"
      assert opts[:message] =~ String.slice(live_head_sha, 0, 12)
      :atomics.add_get(emitted, 1, 1)
      :ok
    end

    condition = :atomics.new(1, [])
    condition_state = fn _ -> if :atomics.get(condition, 1) == 1, do: :firing, else: :unknown end
    event = %{topic: "ticket.#{identifier}.branch.push", sha: pushed_sha}

    EventTopics.route(%State{}, event,
      pull_request_fetcher: pr_fetch,
      alert_emitter: emitter,
      condition_state: condition_state
    )

    assert :atomics.get(emitted, 1) == 1
    :atomics.put(condition, 1, 1)

    EventTopics.route(%State{}, event,
      pull_request_fetcher: pr_fetch,
      alert_emitter: emitter,
      condition_state: condition_state
    )

    assert :atomics.get(emitted, 1) == 1
  end

  test "an answered Command wakes the idle dispatch poll for a stopped in-progress claim" do
    identifier = "answered-hold-#{System.unique_integer([:positive])}"
    topic = "ticket.#{identifier}.agent.decision.answered"
    test_pid = self()
    state_dir = Aiur.TestSupport.tmp_root!("aiur-event-topics-decisions")

    File.mkdir_p!(state_dir)

    # This test covers the dispatch gate wakeup, so accept delivery locally
    # and keep the fixture out of the retry ladder entirely.
    dispatcher = fn _decision, _opts ->
      send(test_pid, :decision_dispatched)
      {:ok, %{status: :accepted, item: %{id: System.unique_integer([:positive])}}}
    end

    dispatch_scheduler =
      fn owner, message, delay ->
        case message do
          {:dispatch_action, _, _} when delay > 0 ->
            send(test_pid, {:delivery_retry_scheduled, message, delay})
            make_ref()

          _other ->
            Process.send_after(owner, message, delay)
        end
      end

    {:ok, store} =
      DecisionStore.start_link(
        name: nil,
        state_dir: state_dir,
        dispatcher: dispatcher,
        dispatch_scheduler: dispatch_scheduler
      )

    on_exit(fn ->
      if Process.alive?(store), do: GenServer.stop(store)

      Aiur.TestCleanup.rm_rf!(state_dir)
    end)

    decisions =
      for question <- ["Choose the implementation", "Confirm the acceptance"] do
        assert {:ok, %{decision: decision}} =
                 DecisionStore.request(
                   %{"question" => question, "blocking" => true},
                   [
                     ticket: %{identifier: identifier},
                     source: %{agent_id: "event-test", session_id: "s", event_id: nil}
                   ],
                   store
                 )

        decision
      end

    [first, second] = decisions

    answer = fn decision ->
      assert {:ok, %{status: status}} =
               DecisionStore.answer(
                 decision.decision_id,
                 %{
                   "expected_version" => decision.version,
                   "custom_response" => "Proceed",
                   "idempotency_key" => decision.decision_id
                 },
                 [actor: %{kind: :operator, id: "event-test"}],
                 store
               )

      assert status in [:accepted, :duplicate]
      assert_receive :decision_dispatched, 1_000
    end

    answer.(first)
    assert "ticket.*.agent.decision.answered" in Lifecycle.orchestrator_topics()

    now_ms = System.monotonic_time(:millisecond)
    timer_ref = Process.send_after(self(), :idle_poll, 60_000)

    state = %State{
      tick_timer_ref: timer_ref,
      tick_token: make_ref(),
      next_poll_due_at_ms: now_ms + 60_000,
      blocked_ticket_ids: MapSet.new([identifier]),
      claimed: MapSet.new(),
      running: %{},
      last_dispatch_poll_at_ms: now_ms - 30_000
    }

    try do
      woken = EventTopics.route(state, %{topic: topic}, decision_store: store)

      assert woken.next_poll_due_at_ms <= System.monotonic_time(:millisecond) + 1_000
      assert woken.tick_token != state.tick_token
      assert_receive {:tick, token} when token == woken.tick_token, 1_000
      # Another open Command still holds the ticket.
      assert MapSet.member?(woken.blocked_ticket_ids, identifier)
      answer.(second)
      released = EventTopics.route(woken, %{topic: topic}, decision_store: store)
      # Control calls must see the fresh local gate before the tracker poll runs.
      refute MapSet.member?(released.blocked_ticket_ids, identifier)
    after
      Process.cancel_timer(timer_ref)
    end

    refute_received :decision_dispatched
    refute_received {:delivery_retry_scheduled, _, _}

    assert Enum.count(DecisionStore.list(store), fn decision ->
             decision.ticket.identifier == identifier and decision.decision_status == :decided
           end) == 2

    refute Enum.any?(DecisionStore.list(), &(&1.ticket.identifier == identifier))
    GenServer.stop(store)
  end

  describe "classify_event_topic/1" do
    test "returns tagged identifiers for every supported topic shape" do
      assert EventTopics.classify_event_topic("ticket.42.pr.review_comment") ==
               {:pr_review_comment, "42"}

      assert EventTopics.classify_event_topic("ticket.42.issue.commented") ==
               {:issue_commented, "42"}

      assert EventTopics.classify_event_topic("ticket.42.pr.merged") == {:pr_merged, "42"}

      assert EventTopics.classify_event_topic("ticket.42.ci.failed") == {:ci_failed, "42"}
      assert EventTopics.classify_event_topic("ticket.42.ci.passed") == {:ci_passed, "42"}

      assert EventTopics.classify_event_topic("ticket.42.agent.pause.request") ==
               {:pause_request, "42"}

      assert EventTopics.classify_event_topic("ticket.42.agent.unblocked") ==
               {:agent_unblocked, "42"}

      assert EventTopics.classify_event_topic("ticket.42.branch.push") == {:branch_push, "42"}

      assert EventTopics.classify_event_topic("system.main.branch.push") ==
               {:system_branch_push, "main"}
    end

    test "returns nomatch for unknown topics" do
      assert EventTopics.classify_event_topic("ticket.42.unknown") == :nomatch
    end
  end

  describe "pr_merged_opts/1" do
    # #2609: the merged route needs the PR body, not just the merger — the
    # topic's ticket comes from the head branch, so only the body says whether
    # the merge closes the ticket or merely refs it.
    test "carries the merger login and the PR body off the event" do
      event = %{
        topic: "ticket.176.pr.merged",
        pr: %{
          "body" => "Refs #176 (merge does not close the ticket)",
          "merged_by" => %{"login" => "its-everdred"},
          "head" => %{"sha" => "4ab677b8b"}
        }
      }

      assert EventTopics.pr_merged_opts(event) == [
               merged_by_login: "its-everdred",
               pr_body: "Refs #176 (merge does not close the ticket)",
               head_sha: "4ab677b8b"
             ]
    end

    test "reports a nil body and merger for an event carrying no pull request" do
      assert EventTopics.pr_merged_opts(%{topic: "ticket.176.pr.merged"}) == [
               merged_by_login: nil,
               pr_body: nil,
               head_sha: nil
             ]

      assert EventTopics.pr_merged_opts(%{topic: "ticket.176.pr.merged", pr: nil}) == [
               merged_by_login: nil,
               pr_body: nil,
               head_sha: nil
             ]
    end
  end

  describe "parsers" do
    test "reject prefixed and suffixed ticket topics" do
      parsers = [
        &EventTopics.parse_pr_review_comment_topic/1,
        &EventTopics.parse_issue_commented_topic/1,
        &EventTopics.parse_pr_merged_topic/1,
        &EventTopics.parse_ci_failed_topic/1,
        &EventTopics.parse_ci_passed_topic/1,
        &EventTopics.parse_pause_request_topic/1,
        &EventTopics.parse_agent_unblocked_topic/1,
        &EventTopics.parse_branch_push_topic/1
      ]

      for parser <- parsers do
        assert parser.("prefix.ticket.42.branch.push") == :nomatch
        assert parser.("ticket.42.branch.push.suffix") == :nomatch
      end
    end

    test "reject prefixed and suffixed system branch push topics" do
      assert EventTopics.parse_system_branch_push_topic("prefix.system.main.branch.push") ==
               :nomatch

      assert EventTopics.parse_system_branch_push_topic("system.main.branch.push.suffix") ==
               :nomatch
    end
  end
end
