defmodule Aiur.CommandsCLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Aiur.{CommandsCLI, DecisionStore}
  alias AiurWeb.OperatorControlCenter.DecisionPresenter

  @ticket %{identifier: "1592", title: "Commands CLI", url: "https://example.test/issues/1592"}
  @source %{agent_id: "agent-1592", session_id: "private", event_id: "private"}

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Path.join(System.tmp_dir!(), "aiur-commands-cli-#{System.unique_integer([:positive])}")
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

      File.rm_rf!(dir)
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

  test "rejects page-incompatible query combinations", %{store: store} do
    assert {:error, message} = CommandsCLI.build(filter: :open, ticket: "1592", decision_store: store)
    assert message =~ "only supports --ticket"
  end

  defp request!(store, source_id, blocking) do
    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{
                 "source_id" => source_id,
                 "question" => "Should #{source_id} ship?",
                 "blocking" => blocking,
                 "reversibility" => "reversible",
                 "options" => [%{"id" => "ship", "label" => "Ship", "description" => "Deploy the change.", "risk" => "low"}]
               },
               [ticket: @ticket, source: @source, now: ~U[2026-08-08 10:00:00Z]],
               store
             )

    decision
  end
end
