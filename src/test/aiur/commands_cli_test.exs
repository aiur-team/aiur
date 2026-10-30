defmodule Aiur.CommandsCLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Aiur.{CommandsCLI, DecisionStore}
  alias AiurWeb.OperatorControlCenter.DecisionPresenter

  @ticket %{identifier: "1592", title: "Commands CLI", url: "https://example.test/issues/1592"}
  @source %{agent_id: "agent-1592", session_id: "private", event_id: "private"}

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Aiur.TestSupport.tmp_root!("aiur-commands-cli")
    Application.put_env(:aiur, :decision_state_dir, dir)

    {:ok, store} =
      DecisionStore.start_link(
        name: nil,
        state_dir: dir,
        filesystem_sync_fun: fn -> :ok end,
        dispatcher: fn _decision, _opts -> {:ok, %{id: "queued"}} end,
        dispatch_delay_ms: 60_000
      )

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(store)

      case original_override do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{store: store}
  end

  test "lists the dashboard's open rows with blocking filtering and stable snapshot metadata", %{store: store} do
    blocking = request!(store, "blocking", true)
    ordinary = request!(store, "ordinary", false)

    assert {:ok, envelope} = CommandsCLI.build(decision_store: store, decision_metrics: make_ref(), history_fun: fn -> [] end, now: ~U[2026-08-08 12:00:00Z])

    assert envelope["schema_version"] == 1
    assert envelope["page"] == "commands"
    assert envelope["snapshot"]["captured_at"] == "2026-08-08T12:00:00Z"
    assert envelope["request"]["filter"] == "all"

    assert envelope["sources"]["decision_page"] == %{
             "age_ms" => nil,
             "freshness" => "unknown",
             "observed_at" => nil,
             "partial" => false,
             "reasons" => [],
             "state" => "available"
           }

    assert Enum.map(envelope["data"]["page"]["decisions"], & &1["decision_id"]) |> Enum.sort() == Enum.sort([blocking.decision_id, ordinary.decision_id])

    assert {:ok, blocking_envelope} =
             CommandsCLI.build(filter: :blocking, decision_store: store, decision_metrics: make_ref(), history_fun: fn -> [] end)

    assert [row] = blocking_envelope["data"]["page"]["decisions"]
    assert row["decision_id"] == blocking.decision_id
    assert row["blocking"]

    output = capture_io(fn -> assert 0 == CommandsCLI.run(decision_store: store, decision_metrics: make_ref(), history_fun: fn -> [] end) end)
    assert output =~ "1592 (Commands CLI)"
  end

  test "keeps every dashboard lifecycle distinct in the command projection", %{store: store} do
    decision = request!(store, "lifecycle", false)

    lifecycles = %{
      recorded: %{},
      dispatch_pending: %{decision_status: :decided},
      delivered: %{delivery_status: :delivered},
      acknowledged: %{decision_status: :acknowledged},
      resolved: %{decision_status: :resolved},
      delivery_failed: %{delivery_status: :failed},
      superseded: %{revision_sequence: 1}
    }

    assert Map.new(lifecycles, fn {expected, changes} ->
             [row] = DecisionPresenter.present(struct!(decision, changes))
             {expected, %{lifecycle: row.lifecycle, superseded?: row.superseded?}}
           end) == %{
             recorded: %{lifecycle: :recorded, superseded?: false},
             dispatch_pending: %{lifecycle: :dispatch_pending, superseded?: false},
             delivered: %{lifecycle: :delivered, superseded?: false},
             acknowledged: %{lifecycle: :acknowledged, superseded?: false},
             resolved: %{lifecycle: :resolved, superseded?: false},
             delivery_failed: %{lifecycle: :delivery_failed, superseded?: false},
             superseded: %{lifecycle: :recorded, superseded?: true}
           }
  end

  test "expired unanswered blocking Commands remain in the open filter and can be answered", %{store: store} do
    decision = request!(store, "expired-blocking", true, authority: "supervisor_allowed")
    assert {:ok, %{decision: expired}} = DecisionStore.expire(decision.decision_id, "agent_not_running", [now: ~U[2026-08-08 11:00:00Z]], store)
    assert expired.decision_status == :expired

    assert {:ok, open} = CommandsCLI.build(filter: :open, decision_store: store, decision_metrics: make_ref(), history_fun: fn -> [] end)
    assert [row] = open["data"]["page"]["decisions"]
    assert row["decision_id"] == decision.decision_id
    assert row["decision_status"] == "expired"
    assert row["options"] == [%{"id" => "ship", "label" => "Ship", "description" => "Deploy the change.", "risk" => "low", "benefits" => nil, "drawbacks" => nil}]

    assert {:ok, %{status: :accepted, decision: answered}} =
             DecisionStore.answer(
               decision.decision_id,
               %{"idempotency_key" => "answer-after-expiry", "expected_version" => decision.version, "option_id" => "ship"},
               [actor: %{kind: :executor, id: "codex-executor"}],
               store
             )

    assert answered.decision_status == :decided
    assert answered.answer.selected_option_id == "ship"
    assert {:ok, after_answer} = CommandsCLI.build(filter: :open, decision_store: store, decision_metrics: make_ref(), history_fun: fn -> [] end)
    assert after_answer["data"]["page"]["decisions"] == []
  end

  test "renders an exact detail and keeps dispatch pending distinct from resolved", %{store: store} do
    decision = request!(store, "dispatch-pending", false)

    assert {:ok, %{status: :accepted, action: action}} =
             DecisionStore.answer(
               decision.decision_id,
               %{"idempotency_key" => "answer-#{decision.decision_id}", "expected_version" => decision.version, "option_id" => "ship"},
               [actor: %{kind: :operator, id: "operator"}],
               store
             )

    assert {:ok, envelope} =
             CommandsCLI.build(
               filter: :resolved,
               decision_id: decision.decision_id,
               decision_store: store,
               decision_metrics: make_ref(),
               history_fun: fn -> [] end
             )

    assert envelope["data"]["selected"]["question"] == "Should dispatch-pending ship?"
    assert envelope["sources"]["selected_decision"]["state"] == "available"

    assert envelope["data"]["selected"]["options"] == [
             %{
               "benefits" => nil,
               "description" => "Deploy the change.",
               "drawbacks" => nil,
               "id" => "ship",
               "label" => "Ship",
               "risk" => "low"
             }
           ]

    assert envelope["data"]["selected"]["lifecycle"] == "dispatch_pending"
    assert [row] = envelope["data"]["page"]["decisions"]
    assert row["lifecycle"] == "dispatch_pending"

    assert {:ok, %{status: :accepted}} =
             DecisionStore.revise(
               decision.decision_id,
               %{
                 "idempotency_key" => "revision-#{decision.decision_id}",
                 "expected_version" => decision.version,
                 "expected_action_id" => action.action_id,
                 "expected_revision_sequence" => 0,
                 "custom_response" => "Wait for fresh evidence.",
                 "rationale" => "Fresh evidence is required before dispatch."
               },
               [actor: %{kind: :operator, id: "operator"}],
               store
             )

    assert {:ok, superseded} =
             CommandsCLI.build(filter: :resolved, decision_store: store, decision_metrics: make_ref(), history_fun: fn -> [] end)

    assert [superseded_row] = superseded["data"]["page"]["decisions"]
    assert superseded_row["lifecycle"] == "dispatch_pending"
    assert superseded_row["superseded?"]

    output = capture_io(fn -> assert 0 == CommandsCLI.run(json: true, decision_id: decision.decision_id, decision_store: store, decision_metrics: make_ref(), history_fun: fn -> [] end) end)
    assert Jason.decode!(output)["data"]["selected"]["decision_id"] == decision.decision_id
  end

  test "human detail displays status, delivery, recommendation, and full context", %{store: store} do
    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{
          question: "Choose a deployment window?",
          blocking: true,
          context: %{short_summary: "Release coordination", long_context_markdown: "Release is reversible and rollback is available."},
          recommendation: %{option_id: "morning", reason: "More staff are available."},
          options: [%{id: "morning", label: "Morning"}]
        },
        [ticket: @ticket, source: @source],
        store
      )

    output = capture_io(fn -> assert CommandsCLI.run(decision_id: decision.decision_id, decision_store: store, decision_metrics: make_ref(), history_fun: fn -> [] end) == 0 end)

    assert output =~ "status open · delivery not_dispatched"
    assert output =~ "Recommendation: morning: More staff are available."
    assert output =~ "Release is reversible and rollback is available."
  end

  test "rejects page-incompatible query combinations", %{store: store} do
    assert {:error, message} = CommandsCLI.build(filter: :open, ticket: "1592", decision_store: store)
    assert message =~ "only supports --ticket"
  end

  test "JSON rows and detail carry clock-derived ages and freshness", %{store: store} do
    decision = request!(store, "ages", false)
    at = ~U[2026-08-08 11:00:00Z]

    assert {:ok, _} =
             DecisionStore.record_command_fact(decision.decision_id, :routed, %{policy: :human_only, state: :with_human, cause: nil, at: at, actor: %{kind: :system, id: "routing"}}, server: store)

    assert {:ok, envelope} = CommandsCLI.build(decision_id: decision.decision_id, decision_store: store, decision_metrics: make_ref(), history_fun: fn -> [] end, now: DateTime.add(at, 60))
    assert [row] = envelope["data"]["page"]["decisions"]

    for value <- [row, envelope["data"]["selected"]] do
      assert value["age_ms"] == 3_660_000
      assert value["needs_you_ms"] == 60_000
      assert value["observed_at"] == "2026-08-08T11:01:00Z"
      assert value["freshness"] == "fresh"
    end
  end

  test "answered human-routed Commands have no needs-you age in resolved rows or detail", %{store: store} do
    decision = request!(store, "answered-human", false)
    at = ~U[2026-08-08 11:00:00Z]

    assert {:ok, _} =
             DecisionStore.record_command_fact(decision.decision_id, :routed, %{policy: :human_only, state: :with_human, cause: nil, at: at, actor: %{kind: :system, id: "routing"}}, server: store)

    assert {:ok, %{status: :accepted}} =
             DecisionStore.answer(
               decision.decision_id,
               %{"idempotency_key" => "answered-human", "expected_version" => decision.version, "option_id" => "ship"},
               [actor: %{kind: :operator, id: "operator"}, now: DateTime.add(at, 30)],
               store
             )

    opts = [filter: :resolved, decision_store: store, decision_metrics: make_ref(), history_fun: fn -> [] end, now: DateTime.add(at, 90)]

    for selection <- [[], [decision_id: decision.decision_id]] do
      assert {:ok, envelope} = CommandsCLI.build(opts ++ selection)
      assert [row] = envelope["data"]["page"]["decisions"]
      assert row["decision_id"] == decision.decision_id
      assert row["human_visible_at"] == "2026-08-08T11:00:00Z"
      assert row["route_state"] == "with_human"
      assert row["needs_you_ms"] == nil

      if selection != [], do: assert(envelope["data"]["selected"]["needs_you_ms"] == nil)
      output = capture_io(fn -> assert 0 == CommandsCLI.run(opts ++ selection) end)
      refute output =~ "Needs you since:"
    end
  end

  test "unknown route prints question mark and never guesses Executor ownership", %{store: store} do
    request!(store, "unknown-route", false)
    output = capture_io(fn -> assert 0 == CommandsCLI.run(decision_store: store, decision_metrics: make_ref(), history_fun: fn -> [] end, now: ~U[2026-08-08 10:00:30Z]) end)
    assert output =~ "ID  ROUTE  AGE  WHY  ASKS  TICKET|EXECUTOR"
    assert output =~ "  ?  30s  -  "
    refute output =~ "With Executor"
    assert output =~ "Freshness: fresh; observed: 2026-08-08T10:00:30Z"
  end

  test "unavailable retained store returns exit one" do
    output = capture_io(:stderr, fn -> assert 1 == CommandsCLI.run(decision_store: make_ref()) end)
    assert output =~ "retained data unavailable"
  end

  test "routing filters return exactly human-visible or Executor-owned open Commands", %{store: store} do
    human = request!(store, "human", false)
    both = request!(store, "both", false)
    executor = request!(store, "executor", false)
    resolved = request!(store, "answered-human", false)
    request!(store, "unknown", false)
    at = ~U[2026-08-08 10:00:00Z]

    for {decision, state, policy} <- [{human, :with_human, :human_only}, {both, :with_both, :simultaneous}, {executor, :with_executor, :executor_first}, {resolved, :with_human, :human_only}] do
      assert {:ok, _} = DecisionStore.record_command_fact(decision.decision_id, :routed, %{policy: policy, state: state, cause: nil, at: at, actor: %{kind: :system, id: "routing"}}, server: store)
    end

    assert {:ok, _} = DecisionStore.answer(resolved.decision_id, %{"idempotency_key" => "answer-human", "expected_version" => 1, "option_id" => "ship"}, [actor: %{kind: :operator, id: "test"}], store)

    for {filter, expected} <- [{"needs-you", [human.decision_id, both.decision_id]}, {"with-executor", [executor.decision_id]}] do
      assert {:ok, envelope} = CommandsCLI.build(filter: filter, decision_store: store, decision_metrics: make_ref(), history_fun: fn -> [] end, now: at)
      assert Enum.sort(Enum.map(envelope["data"]["page"]["decisions"], & &1["decision_id"])) == Enum.sort(expected)
    end
  end

  test "from-executor uses the provider requester filter and preserves its page scope", %{store: store} do
    worker = request!(store, "worker-request", false)
    executor = request!(store, "executor-request", false, requester: %{kind: :executor, executor_id: "executor"})
    assert {:ok, envelope} = CommandsCLI.build(filter: "from-executor", decision_store: store, decision_metrics: make_ref(), history_fun: fn -> [] end)
    assert [row] = envelope["data"]["page"]["decisions"]
    assert row["decision_id"] == executor.decision_id
    refute row["decision_id"] == worker.decision_id
    assert envelope["data"]["page"]["requester_page"] == %{"count" => 1, "partial?" => false}
    assert envelope["data"]["page"]["pagination"]["total"] == nil
  end

  defp request!(store, source_id, blocking, extra \\ []) do
    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{
                 "source_id" => source_id,
                 "question" => "Should #{source_id} ship?",
                 "blocking" => blocking,
                 "reversibility" => "reversible",
                 "authority" => Keyword.get(extra, :authority, "human_required"),
                 "context" => %{"authority_basis" => "security"},
                 "options" => [%{"id" => "ship", "label" => "Ship", "description" => "Deploy the change.", "risk" => "low"}]
               },
               Keyword.merge([ticket: @ticket, source: @source, now: ~U[2026-08-08 10:00:00Z]], Keyword.take(extra, [:requester])),
               store
             )

    decision
  end
end
