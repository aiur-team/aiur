defmodule Aiur.DecisionAttentionTest do
  use Aiur.TestSupport

  alias Aiur.{AlertFeed, DecisionAttention, Issue}
  alias Aiur.Config.Paths
  alias Aiur.Events.SubscriptionStore

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
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
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

    assert_receive {:decision_alert, %{question: "Should this facade target change?", slug: "scope-question"}}
    assert SubscriptionStore.snapshot(identifier).open_attentions == ["scope-question"]

    send(pid, {:reask, {identifier, "scope-question"}})
    assert_receive {:decision_alert, %{question: "Should this facade target change?"}}

    assert :ok = DecisionAttention.resolve(name, issue, "scope-question")
    assert_receive {:decision_resolved, %{slug: "scope-question"}}
    assert SubscriptionStore.snapshot(identifier).open_attentions == []

    send(pid, {:reask, {identifier, "scope-question"}})
    refute_receive {:decision_alert, _}
  end

  test "writes a needs-attention alert with the operator question" do
    identifier = "DECISION-ALERT-#{System.unique_integer([:positive])}"
    workspace = Path.join(System.tmp_dir!(), "aiur-decision-attention-#{System.unique_integer([:positive])}")
    issue = %Issue{identifier: identifier, title: "Needs a decision"}

    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    {_pid, name} = start_attention([])

    assert :ok = DecisionAttention.open(name, issue, workspace, nil, "scope-question", "Should this facade target change?")

    log = Path.join(workspace, "logs/agent.ndjson") |> File.read!()
    assert log =~ "ticket.#{identifier}.agent.attention.scope-question"
    assert log =~ "Operator decision required: Should this facade target change?"
    assert log =~ "\"needs_attention\":true"
  end

  test "remote decision resolution clears the central attention feed" do
    identifier = "DECISION-REMOTE-#{System.unique_integer([:positive])}"
    workspace = Path.join(System.tmp_dir!(), "aiur-decision-remote-#{System.unique_integer([:positive])}")
    issue = %Issue{identifier: identifier, title: "Remote decision"}

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

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

    assert [%{"topic" => ^expected_topic}] =
             AlertFeed.list(roots: [], log_roots: [Paths.log_root_dir()], needs_attention: true)

    assert :ok = DecisionAttention.resolve(name, issue, "scope-question")
    assert AlertFeed.list(roots: [], log_roots: [Paths.log_root_dir()], needs_attention: true) == []
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

    assert_receive {:step, :projected, payload, opts}
    assert payload["source_id"] == "legacy_attention:scope-question"
    assert payload["options"] == []
    assert opts[:legacy_attention].topic == "ticket.#{identifier}.agent.attention.scope-question"
    assert opts[:source].session_id == "thread-1"
    assert_receive {:step, :alerted, %{slug: "scope-question"}}
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

    refute_receive {:decision_alert, _}
    assert SubscriptionStore.snapshot(identifier) == :not_found
  end

  test "startup imports active attentions without emitting an immediate duplicate alert" do
    identifier = "DECISION-IMPORT-#{System.unique_integer([:positive])}"
    test_pid = self()

    loader = fn ->
      [
        %{
          identifier: identifier,
          slug: "scope-question",
          question: "Should this facade target change?",
          topic: "ticket.#{identifier}.agent.attention.scope-question",
          source_created_at: ~U[2026-07-12 01:00:00Z]
        }
      ]
    end

    projector = fn payload, opts ->
      send(test_pid, {:imported, payload, opts})
      {:ok, %{status: :accepted, decision: %{decision_id: "dec_import", version: 1}}}
    end

    {_pid, _name} =
      start_attention(
        attention_loader: loader,
        decision_projector: projector,
        alert_emitter: fn attention -> send(test_pid, {:decision_alert, attention}) end
      )

    assert_receive {:imported, payload, opts}
    assert payload["created_at"] == "2026-07-12T01:00:00Z"
    assert opts[:ticket].identifier == identifier
    assert opts[:legacy_attention].slug == "scope-question"
    assert opts[:legacy_import]
    refute_receive {:decision_alert, _}

    assert eventually(fn ->
             match?(%{open_attentions: ["scope-question"]}, SubscriptionStore.snapshot(identifier))
           end)
  end

  test "startup import bounds projection fanout and restored timers" do
    prefix = "DECISION-IMPORT-LIMIT-#{System.unique_integer([:positive])}"
    test_pid = self()

    attentions =
      for index <- 1..5 do
        identifier = "#{prefix}-#{index}"

        %{
          identifier: identifier,
          slug: "scope-question",
          question: "Question #{index}?",
          topic: "ticket.#{identifier}.agent.attention.scope-question",
          source_created_at: ~U[2026-07-12 01:00:00Z]
        }
      end

    projector = fn payload, opts ->
      send(test_pid, {:bounded_import, opts[:ticket].identifier, payload["question"]})
      accepted_projection().(payload, opts)
    end

    {pid, _name} =
      start_attention(
        attention_loader: fn -> attentions end,
        decision_projector: projector,
        import_limit: 2
      )

    first_identifier = "#{prefix}-1"
    second_identifier = "#{prefix}-2"
    assert_receive {:bounded_import, ^first_identifier, "Question 1?"}
    assert_receive {:bounded_import, ^second_identifier, "Question 2?"}
    refute_receive {:bounded_import, _, _}
    assert eventually(fn -> :sys.get_state(pid).importing? == false end)
    assert map_size(:sys.get_state(pid).attentions) == 2
  end

  test "a live open wins over a delayed startup import for the same attention" do
    identifier = "DECISION-IMPORT-RACE-#{System.unique_integer([:positive])}"
    issue = %Issue{identifier: identifier, title: "Live context"}
    test_pid = self()

    loader = fn ->
      send(test_pid, {:loader_ready, self()})

      receive do
        :release ->
          [
            %{
              identifier: identifier,
              slug: "scope-question",
              question: "Stale imported question?",
              topic: "ticket.#{identifier}.agent.attention.scope-question",
              source_created_at: ~U[2026-07-12 01:00:00Z]
            }
          ]
      end
    end

    projector = fn payload, _opts ->
      send(test_pid, {:projected, payload["question"]})
      {:ok, %{status: :accepted, decision: %{decision_id: "dec_import_race", version: 1}}}
    end

    {pid, name} =
      start_attention(
        attention_loader: loader,
        decision_projector: projector,
        alert_emitter: fn attention -> send(test_pid, {:decision_alert, attention}) end
      )

    assert_receive {:loader_ready, loader_pid}

    assert {:ok, _result} =
             DecisionAttention.open_with_decision(
               name,
               issue,
               "/live/workspace",
               "live-worker",
               "scope-question",
               "Live question?",
               []
             )

    assert_receive {:projected, "Live question?"}
    assert_receive {:decision_alert, %{question: "Live question?", workspace: "/live/workspace"}}

    ref = Process.monitor(loader_pid)
    send(loader_pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^loader_pid, :normal}
    assert eventually(fn -> :sys.get_state(pid).importing? == false end)

    refute_receive {:projected, "Stale imported question?"}

    send(pid, {:reask, {identifier, "scope-question"}})
    assert_receive {:decision_alert, %{question: "Live question?", worker_host: "live-worker"}}
  end

  test "a resolution during startup prevents a delayed import from reopening the attention" do
    identifier = "DECISION-IMPORT-RESOLVE-#{System.unique_integer([:positive])}"
    issue = %Issue{identifier: identifier}
    test_pid = self()

    loader = fn ->
      send(test_pid, {:loader_ready, self()})

      receive do
        :release ->
          [
            %{
              identifier: identifier,
              slug: "scope-question",
              question: "Already resolved?",
              topic: "ticket.#{identifier}.agent.attention.scope-question",
              source_created_at: ~U[2026-07-12 01:00:00Z]
            }
          ]
      end
    end

    {pid, name} =
      start_attention(
        attention_loader: loader,
        decision_projector: fn payload, _opts ->
          send(test_pid, {:unexpected_projection, payload})
          accepted_projection().(payload, [])
        end,
        resolution_emitter: fn _attention -> :ok end
      )

    assert_receive {:loader_ready, loader_pid}
    assert :ok = DecisionAttention.resolve(name, issue, "scope-question")

    ref = Process.monitor(loader_pid)
    send(loader_pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^loader_pid, :normal}
    assert eventually(fn -> :sys.get_state(pid).importing? == false end)

    refute_receive {:unexpected_projection, _payload}
    assert SubscriptionStore.snapshot(identifier).open_attentions == []
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
