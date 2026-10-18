defmodule Aiur.Orchestrator.IssueSync.TransitionAlertsTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.DecisionAttention
  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.ExecutorListener
  alias Aiur.ExecutorWakeInbox
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State

  test "issue poll resolves a stranded reminder after observing ci-wait" do
    ticket = %{issue("stranded-ci-wait", "ci-wait") | identifier: "stranded-ci-wait"}
    topic = "ticket.#{ticket.identifier}.agent.attention.stranded-requeued"

    assert :ok = DecisionAttention.open(ticket, nil, nil, "stranded-requeued", "Restore dispatch")
    assert Enum.any?(Aiur.AlertFeed.list(), &(&1["topic"] == topic and &1["needs_attention"]))

    state =
      IssueSync.sync_polled_issue_state(
        %State{},
        [ticket],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    refute Enum.any?(Aiur.AlertFeed.list(), &(&1["topic"] == topic and &1["needs_attention"]))
    refute MapSet.member?(state.active_attention_topics, topic)
  end

  test "alerts when the tracker adds or removes agent:paused" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("ticket.its-everdred/aiur#pause-transition.agent.paused")
    :ok = Exchange.subscribe("ticket.its-everdred/aiur#pause-transition.agent.unpaused")
    :ok = Exchange.subscribe("ticket.its-everdred/aiur#pause-transition.agent.paused.resolved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    previous = issue("pause-transition", "in-progress")
    paused = %{previous | paused: true}

    state =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{previous.id => previous}},
        [paused],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert state.last_polled_issues == %{paused.id => paused}

    assert_received {:event, %{topic: "ticket.its-everdred/aiur#pause-transition.agent.paused"} = event}

    assert event["reason"] =~ "tracker pause override"
    assert event["reason"] =~ "clears when the operator removes agent:paused"
    assert event["needs_attention"] == true

    _ =
      IssueSync.sync_polled_issue_state(
        state,
        [previous],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_received {:event, %{topic: "ticket.its-everdred/aiur#pause-transition.agent.unpaused"} = event}

    assert event["reason"] =~ "No operator action is needed"
    assert event["needs_attention"] == false
    assert_received {:event, %{topic: "ticket.its-everdred/aiur#pause-transition.agent.paused.resolved"}}
  end

  test "records exactly one Executor wake for human-review despite unrelated attention traffic" do
    Publisher.set_tracked_fn(fn _ -> true end)
    on_exit(fn -> Publisher.set_tracked_fn(fn _ -> true end) end)
    previous = issue("handoff", "in-progress")
    start_supervised!({ExecutorWakeInbox, debounce_ms: 10})
    listener = start_supervised!({ExecutorListener, name: Aiur.ExecutorListener.IssueSyncHandoffTest, patterns: ["ticket.#{previous.identifier}.agent.handoff.human_review"]})
    {:ok, _, _} = Publisher.publish("ticket.42.agent.attention.comment_wake_state_unresolved", %{"needs_attention" => false})
    sha = String.duplicate("c", 40)
    :ok = ResourceStore.put_resource(ResourceStore.key_for_repo(:branch_pull_request_listing, "its-everdred/aiur", previous.id), %{"number" => 3019, "head" => %{"sha" => sha}})

    state =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{previous.id => previous}},
        [%{previous | state: "human-review"}],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert state.last_polled_issues[previous.id].state == "human-review"
    # Publication sends from this process; the listener barrier waits for both deliveries and synchronous enqueue.
    :sys.get_state(listener)

    assert {:ok, [%{"topic" => "ticket.its-everdred/aiur#handoff.agent.handoff.human_review", "pr_number" => 3019, "head_sha" => ^sha}]} =
             ExecutorWakeInbox.wait(0)

    assert [%{"topic" => "ticket.its-everdred/aiur#handoff.agent.handoff.human_review"}] = ExecutorWakeInbox.pending()
  end

  describe "handoff wake from both the tracker refresh and the CI poll" do
    setup do
      Publisher.set_tracked_fn(fn _ -> true end)
      on_exit(fn -> Publisher.set_tracked_fn(fn _ -> true end) end)
      start_supervised!({ExecutorWakeInbox, debounce_ms: 10})
      :ok
    end

    test "publishes one wake per head, filled from an approval at that head" do
      {listener, sha} = observe_handoff_twice("handoff-approved", 4799, fn sha -> [review("APPROVED", sha)] end)
      :sys.get_state(listener)

      assert {:ok, [%{"head_sha" => ^sha, "last_review_sha" => ^sha, "needs_attention" => false, "count" => 1}]} = ExecutorWakeInbox.wait(500)
    end

    test "keeps needs_attention when the latest review is at an older head" do
      older = String.duplicate("0", 40)
      {listener, sha} = observe_handoff_twice("handoff-stale-review", 4800, fn _sha -> [review("APPROVED", older)] end)
      :sys.get_state(listener)

      assert {:ok, [%{"head_sha" => ^sha, "last_review_sha" => ^older, "needs_attention" => true}]} = ExecutorWakeInbox.wait(500)
    end
  end

  defp observe_handoff_twice(name, pr_number, reviews) do
    previous = issue(name, "in-progress")
    current = %{previous | state: "human-review"}
    listener = start_supervised!({ExecutorListener, name: Module.concat(__MODULE__, name), patterns: ["ticket.#{previous.identifier}.agent.handoff.human_review"]})
    sha = 40 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower) |> binary_part(0, 40)
    pr = %{"number" => pr_number, "head" => %{"sha" => sha}, "user" => %{"login" => "agent-bot"}}
    :ok = ResourceStore.put_resource(ResourceStore.key_for_repo(:branch_pull_request_listing, "its-everdred/aiur", previous.id), pr)
    :ok = ResourceStore.put_resource(ResourceStore.key_for_repo(:pull_request_reviews, "its-everdred/aiur", pr_number), reviews.(sha))

    state =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{previous.id => previous}, human_review_observed_ids: MapSet.new()},
        [current],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    # The CI poll keeps its own observed set, so it sees the same flip as new.
    _ = IssueSync.observe_human_review_handoffs(state, [current])
    {listener, sha}
  end

  defp review(state, sha),
    do: %{"user" => %{"login" => "reviewer"}, "state" => state, "commit_id" => sha, "submitted_at" => "2026-10-16T01:24:00Z"}

  test "resolves an observed error attention when the issue moves to human-review" do
    Publisher.set_tracked_fn(fn _ -> true end)
    on_exit(fn -> Publisher.set_tracked_fn(fn _ -> true end) end)

    previous = issue("error-to-review", "error")
    current = %{previous | state: "human-review"}
    topic = "ticket.#{previous.identifier}.agent.attention.error-observed_tracker_error.resolved"
    :ok = Exchange.subscribe(topic)
    on_exit(fn -> Exchange.unsubscribe(topic) end)

    _state =
      IssueSync.sync_polled_issue_state(
        %State{
          last_polled_issues: %{previous.id => previous},
          observed_error_alerts: MapSet.new([previous.id]),
          active_attention_topics: MapSet.new([String.trim_trailing(topic, ".resolved")])
        },
        [current],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_received {:event, %{topic: ^topic} = event}
    assert event["needs_attention"] == false
  end
end
