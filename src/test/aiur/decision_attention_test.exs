defmodule Aiur.DecisionAttentionTest do
  use Aiur.TestSupport

  alias Aiur.{AlertFeed, DecisionAttention, DecisionStore, Issue}

  alias Aiur.Events.{Exchange, SubscriptionStore}

  defp accepted_projection do
    fn _payload, _opts ->
      {:ok, %{status: :accepted, decision: %{decision_id: "dec_test", version: 1}}}
    end
  end

  defp start_attention(opts) do
    defaults = [
      name: Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}"),
      reask_interval_ms: 60_000,
      attention_loader: fn -> [] end,
      decision_projector: accepted_projection()
    ]

    opts = Keyword.merge(defaults, opts)
    {:ok, pid} = DecisionAttention.start_link(opts)
    on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)
    {pid, Keyword.fetch!(opts, :name)}
  end

  test "opens, re-asks, and resolves an operator-decision attention" do
    identifier = "DECISION-#{System.unique_integer([:positive])}"
    issue = %Issue{identifier: identifier, title: "Needs a decision"}
    test_pid = self()

    {pid, name} =
      start_attention(
        reask_interval_ms: 60_000,
        alert_emitter: fn attention -> send(test_pid, {:decision_alert, attention}) end,
        resolution_emitter: fn attention -> send(test_pid, {:decision_resolved, attention}) end
      )

    assert :ok = DecisionAttention.open(name, issue, nil, nil, "scope-question", "Should this facade target change?")

    assert_receive {:decision_alert, %{question: "Should this facade target change?", slug: "scope-question"}}, 1000
    assert SubscriptionStore.snapshot(identifier).open_attentions == ["scope-question"]

    send(pid, {:reask, {identifier, "scope-question"}})
    assert_receive {:decision_alert, %{question: "Should this facade target change?"}}, 1000

    assert :ok = DecisionAttention.resolve(name, issue, "scope-question")
    assert_receive {:decision_resolved, %{slug: "scope-question"}}, 1000
    assert SubscriptionStore.snapshot(identifier).open_attentions == []

    send(pid, {:reask, {identifier, "scope-question"}})
    refute_receive {:decision_alert, _}, 100
  end

  test "answered operator decision resolves its attention on the next reminder" do
    identifier = "DECISION-ANSWERED-#{System.unique_integer([:positive])}"
    issue = %Issue{identifier: identifier}
    dir = Aiur.TestSupport.tmp_root!("aiur-answered-attention")
    {:ok, store} = DecisionStore.start_link(name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000)
    on_exit(fn -> Aiur.TestSupport.safe_stop(store) end)
    test_pid = self()

    {pid, name} =
      start_attention(
        decision_store: store,
        decision_projector: fn payload, opts -> DecisionStore.project_attention(payload, opts, store) end,
        alert_emitter: fn attention -> send(test_pid, {:decision_alert, attention}) end,
        resolution_emitter: fn attention -> send(test_pid, {:decision_resolved, attention}) end
      )

    assert {:ok, %{decision: decision}} =
             DecisionAttention.open_with_decision(name, issue, nil, nil, "operator-decision", "Which scope?", [])

    receive_barrier({:decision_alert, %{slug: "operator-decision"}})

    # Both open and deferred decisions still need an answer.
    send(pid, {:reask, {identifier, "operator-decision"}})
    :sys.get_state(pid)
    receive_barrier({:decision_alert, %{slug: "operator-decision"}})
    assert {:ok, %{decision: deferred}} = DecisionStore.defer(decision.decision_id, [actor: %{kind: :operator, id: "test"}], store)
    assert deferred.decision_status == :deferred
    send(pid, {:reask, {identifier, "operator-decision"}})
    :sys.get_state(pid)
    receive_barrier({:decision_alert, %{slug: "operator-decision"}})

    assert {:ok, %{decision: other}} =
             DecisionStore.project_attention(
               %{"source_id" => "unrelated", "kind" => "scope", "question" => "Another ticket?", "blocking" => false, "options" => []},
               [ticket: %{identifier: identifier <> "-OTHER"}, source: %{}, legacy_attention: %{slug: "operator-decision", topic: "ticket.#{identifier}-OTHER.agent.attention.operator-decision"}],
               store
             )

    assert {:ok, %{status: :accepted}} =
             DecisionStore.answer(
               decision.decision_id,
               %{"idempotency_key" => "answer", "expected_version" => deferred.version, "custom_response" => "Use the current scope."},
               [actor: %{kind: :operator, id: "test"}],
               store
             )

    assert {:ok, %{decision_status: :decided}} = DecisionStore.get(decision.decision_id, store)
    assert {:ok, %{decision_status: :open}} = DecisionStore.get(other.decision_id, store)
    send(pid, {:reask, {identifier, "operator-decision"}})
    assert :sys.get_state(pid).attentions == %{}
    receive_barrier({:decision_resolved, %{slug: "operator-decision"}})
    assert SubscriptionStore.snapshot(identifier).open_attentions == []
    refute_received {:decision_alert, _}

    send(pid, {:reask, {identifier, "operator-decision"}})
    assert :sys.get_state(pid).attentions == %{}
    refute_received {:decision_alert, _}
  end

  test "expires a stale main CI attention instead of re-raising it" do
    identifier = "MAIN-CI-#{System.unique_integer([:positive])}"
    issue = %Issue{identifier: identifier, title: "Main CI observer"}
    workspace = Aiur.TestSupport.tmp_root!("aiur-main-ci-attention")
    topic = "ticket.#{identifier}.agent.attention.main-red"
    resolved_topic = topic <> ".resolved"
    opened_at = ~U[2026-09-26 12:24:57Z]
    {:ok, clock} = Agent.start_link(fn -> opened_at end)

    File.mkdir_p!(workspace)
    :ok = Exchange.subscribe(topic)
    :ok = Exchange.subscribe(resolved_topic)

    on_exit(fn ->
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      Aiur.TestCleanup.rm_rf!(workspace)
    end)

    {pid, name} =
      start_attention(
        now_fun: fn -> Agent.get(clock, & &1) end,
        reask_interval_ms: 60_000,
        condition_attention_ttl_ms: 60_000
      )

    assert :ok =
             DecisionAttention.open(
               name,
               issue,
               workspace,
               nil,
               "main-red",
               "Main CI is red on the interfaces mirror test."
             )

    assert_receive {:event, %{"needs_attention" => true, topic: ^topic}}, 1_000

    Agent.update(clock, &DateTime.add(&1, 60, :second))
    send(pid, {:reask, {identifier, "main-red"}})

    assert_receive {:event, %{"needs_attention" => false, topic: ^resolved_topic}}, 1_000
    assert :sys.get_state(pid).attentions == %{}

    send(pid, {:reask, {identifier, "main-red"}})
    assert :sys.get_state(pid).attentions == %{}
    refute_received {:event, %{topic: ^topic}}
  end

  # Regression guard: condition-attention freshness follows the latest assertion.

  test "a fresh main CI assertion restarts the expiry window" do
    identifier = "MAIN-CI-REASSERT-#{System.unique_integer([:positive])}"
    issue = %Issue{identifier: identifier, title: "Main CI observer"}
    workspace = Aiur.TestSupport.tmp_root!("aiur-main-ci-reassert")
    topic = "ticket.#{identifier}.agent.attention.main-red"
    resolved_topic = topic <> ".resolved"
    opened_at = ~U[2026-09-26 12:24:57Z]
    {:ok, clock} = Agent.start_link(fn -> opened_at end)

    File.mkdir_p!(workspace)
    :ok = Exchange.subscribe(topic)
    :ok = Exchange.subscribe(resolved_topic)

    on_exit(fn ->
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      Aiur.TestCleanup.rm_rf!(workspace)
    end)

    {pid, name} =
      start_attention(
        now_fun: fn -> Agent.get(clock, & &1) end,
        reask_interval_ms: 60_000,
        condition_attention_ttl_ms: 60_000
      )

    assert :ok =
             DecisionAttention.open(
               name,
               issue,
               workspace,
               nil,
               "main-red",
               "Main CI is still red."
             )

    assert_receive {:event, %{"needs_attention" => true, topic: ^topic}}, 1_000

    Agent.update(clock, &DateTime.add(&1, 45, :second))

    assert :ok =
             DecisionAttention.open(
               name,
               issue,
               workspace,
               nil,
               "main-red",
               "Main CI is still red."
             )

    assert_receive {:event, %{"needs_attention" => true, topic: ^topic}}, 1_000

    Agent.update(clock, &DateTime.add(&1, 30, :second))
    send(pid, {:reask, {identifier, "main-red"}})

    assert_receive {:event, %{"needs_attention" => true, topic: ^topic}}, 1_000
    refute_received {:event, %{"needs_attention" => false, topic: ^resolved_topic}}
  end

  test "does not restore a stale main CI attention after restart" do
    identifier = "MAIN-CI-IMPORT-#{System.unique_integer([:positive])}"
    slug = "main-ci-red-interfaces-mirror"
    workspace = Aiur.TestSupport.tmp_root!("aiur-main-ci-import")
    topic = "ticket.#{identifier}.agent.attention.#{slug}"
    resolved_topic = topic <> ".resolved"
    opened_at = ~U[2026-09-26 12:24:57Z]
    now = DateTime.add(opened_at, 16, :minute)

    File.mkdir_p!(workspace)
    :ok = Exchange.subscribe(topic)
    :ok = Exchange.subscribe(resolved_topic)

    on_exit(fn ->
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      Aiur.TestCleanup.rm_rf!(workspace)
    end)

    {pid, _name} =
      start_attention(
        now_fun: fn -> now end,
        condition_attention_ttl_ms: 60_000,
        attention_loader: fn ->
          [
            %{
              identifier: identifier,
              slug: slug,
              question: "Main CI is red.",
              topic: topic,
              source_created_at: opened_at
            }
          ]
        end
      )

    assert_receive {:event, %{"needs_attention" => false, topic: ^resolved_topic}}, 1_000
    assert :sys.get_state(pid).attentions == %{}
    refute_received {:event, %{topic: ^topic}}
  end

  test "writes a needs-attention alert with the operator question" do
    identifier = "DECISION-ALERT-#{System.unique_integer([:positive])}"
    workspace = Aiur.TestSupport.tmp_root!("aiur-decision-attention")
    issue = %Issue{identifier: identifier, title: "Needs a decision"}

    File.mkdir_p!(workspace)

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(workspace)
    end)

    {_pid, name} = start_attention([])

    assert :ok = DecisionAttention.open(name, issue, workspace, nil, "scope-question", "Should this facade target change?")

    log = Path.join(workspace, "logs/agent.ndjson") |> File.read!()
    assert log =~ "ticket.#{identifier}.agent.attention.scope-question"
    assert log =~ "Executor decision required: Should this facade target change?"
    assert log =~ "\"needs_attention\":true"
  end

  test "remote decision resolution clears the central attention feed" do
    identifier = "DECISION-REMOTE-#{System.unique_integer([:positive])}"
    workspace = Aiur.TestSupport.tmp_root!("aiur-decision-remote")
    issue = %Issue{identifier: identifier, title: "Remote decision"}

    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

    {_pid, name} = start_attention([])

    assert :ok =
             DecisionAttention.open(
               name,
               issue,
               workspace,
               "remote-worker",
               "scope-question",
               "Should this facade target change?"
             )

    expected_topic = "ticket.#{identifier}.agent.attention.scope-question"

    assert [%{"topic" => ^expected_topic}] = Enum.filter(AlertFeed.list(roots: [], needs_attention: true), &(&1["topic"] == expected_topic))

    assert :ok = DecisionAttention.resolve(name, issue, "scope-question")

    assert Enum.filter(AlertFeed.list(roots: [], needs_attention: true), &(&1["topic"] == expected_topic)) == []
  end

  test "persists before opening the subscription or emitting the alert" do
    identifier = "DECISION-ORDER-#{System.unique_integer([:positive])}"
    issue = %Issue{identifier: identifier, title: "Ordered decision"}
    test_pid = self()

    projector = fn payload, opts ->
      send(test_pid, {:step, :projected, payload, opts})
      {:ok, %{status: :accepted, decision: %{decision_id: "dec_order", version: 1}}}
    end

    {_pid, name} =
      start_attention(
        decision_projector: projector,
        alert_emitter: fn attention -> send(test_pid, {:step, :alerted, attention}) end
      )

    assert {:ok, %{decision: %{decision_id: "dec_order"}}} =
             DecisionAttention.open_with_decision(
               name,
               issue,
               nil,
               nil,
               "scope-question",
               "Should this facade target change?",
               source: %{agent_id: "codex", session_id: "thread-1", event_id: "call-1"}
             )

    assert_receive {:step, :projected, payload, opts}, 1000
    assert payload["source_id"] == "legacy_attention:scope-question"
    assert payload["options"] == []
    assert opts[:legacy_attention].topic == "ticket.#{identifier}.agent.attention.scope-question"
    assert opts[:source].session_id == "thread-1"
    assert_receive {:step, :alerted, %{slug: "scope-question"}}, 1000
    assert SubscriptionStore.snapshot(identifier).open_attentions == ["scope-question"]
  end

  test "a persistence failure has no alert, subscription, or timer side effect" do
    identifier = "DECISION-FAIL-#{System.unique_integer([:positive])}"
    issue = %Issue{identifier: identifier, title: "Rejected decision"}
    test_pid = self()

    {_pid, name} =
      start_attention(
        decision_projector: fn _payload, _opts -> {:error, :store_down} end,
        alert_emitter: fn attention -> send(test_pid, {:decision_alert, attention}) end
      )

    assert DecisionAttention.open(
             name,
             issue,
             nil,
             nil,
             "scope-question",
             "Should this facade target change?"
           ) == {:error, :store_down}

    refute_receive {:decision_alert, _}, 100
    assert SubscriptionStore.snapshot(identifier) == :not_found
  end

  test "projects an already-persisted parent follow-up without creating a child Decision" do
    identifier = "DECISION-PARENT-#{System.unique_integer([:positive])}"
    issue = %Issue{identifier: identifier, title: "Parent-owned follow-up"}
    test_pid = self()

    {_pid, name} =
      start_attention(
        decision_projector: fn _payload, _opts -> send(test_pid, :unexpected_projection) end,
        alert_emitter: fn attention -> send(test_pid, {:decision_alert, attention}) end
      )

    assert :ok =
             DecisionAttention.open_persisted(
               name,
               issue,
               nil,
               nil,
               "decision-revision-parent",
               "What should happen next?"
             )

    refute_receive :unexpected_projection, 100
    assert_receive {:decision_alert, %{slug: "decision-revision-parent"}}, 1000
    assert SubscriptionStore.snapshot(identifier).open_attentions == ["decision-revision-parent"]
  end
end
