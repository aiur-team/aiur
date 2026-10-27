Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.PublicProjectionTest do
  use Aiur.DecisionStoreCase, async: false

  import ExUnit.CaptureIO
  import Plug.Conn
  import Plug.Test

  alias Aiur.Commands.Projection
  alias Aiur.{CommandsCLI, DecisionApi}
  alias Aiur.DecisionApi.PublicProjection
  alias AiurWeb.DecisionApiController

  @fixture Path.expand("../../../../packages/aiur-contracts/fixtures/command.v2.json", __DIR__)

  test "v1 HTTP detail renders default attribution and summary without a payload version", %{dir: dir} do
    store = start_store!(dir)
    summary = "A summary with more than forty characters for a legacy Command"
    assert {:ok, %{decision: decision}} = request(store, %{question: "Choose scope?", blocking: false, context: %{short_summary: summary}})
    conn = controller_conn(store) |> DecisionApiController.show(%{"decision_id" => decision.decision_id})
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["short_label"] == String.slice(summary, 0, 40)
    assert body["requester"] == %{"kind" => "worker", "ticket" => "979"}
    assert body["origin"] == "emit_event"
    assert body["native"] == nil
    assert body["questions"] == []
    refute Map.has_key?(body, "payload_version")
    GenServer.stop(store)
  end

  test "attributed read API and JSON CLI preserve rows and redact native correlation", %{dir: dir} do
    store = start_store!(dir)
    assert {:ok, %{decision: legacy}} = request(store, %{source_id: "legacy", question: "Legacy?", blocking: false})

    attrs = [
      requester: %{kind: :executor, executor_id: "operator", session_ref: "executor-session", harness: "codex"},
      origin: :native_question,
      native: %{harness: :codex, hold: :in_band, question_ids: ["scope"], native_ref: "SECRET_NATIVE_REF", call_id: "SECRET_CALL", turn_id: "SECRET_TURN"},
      questions: [%{"id" => "scope", "question" => "Choose scope?", "options" => [%{"id" => "small", "label" => "Small"}]}]
    ]

    assert {:ok, %{decision: decision}} = request(store, %{source_id: "v2", question: "Choose scope?", blocking: false, context: %{short_summary: "Scope"}}, attrs)
    assert {:ok, api} = DecisionApi.get(decision.decision_id, store: store)
    assert {:ok, page} = DecisionApi.list(%{}, store: store)
    assert length(page["decisions"]) == 2
    assert Enum.find(page["decisions"], &(&1["decision_id"] == decision.decision_id))["requester"] == api["requester"]
    assert api["payload_version"] == 2
    assert api["requester"] == %{"kind" => "executor", "executor_id" => "operator", "session_ref" => "executor-session", "harness" => "codex", "ticket" => nil}
    assert api["origin"] == "native_question"
    assert api["native"] == %{"harness" => "codex", "hold" => "in_band", "question_ids" => ["scope"]}
    assert api["questions"] == attrs[:questions]
    assert api["short_label"] == "Scope"

    output = capture_io(fn -> assert 0 == CommandsCLI.run(json: true, decision_id: decision.decision_id, decision_store: store, decision_metrics: make_ref(), history_fun: fn -> [] end) end)
    cli = Jason.decode!(output)["data"]
    assert length(cli["page"]["decisions"]) == 2
    assert Enum.sort(Enum.map(cli["page"]["decisions"], & &1["decision_id"])) == Enum.sort([legacy.decision_id, decision.decision_id])

    for row <- [cli["selected"], Enum.find(cli["page"]["decisions"], &(&1["decision_id"] == decision.decision_id))] do
      assert Map.take(row, ~w(requester origin native questions short_label)) == Map.take(api, ~w(requester origin native questions short_label))
    end

    for secret <- ~w(SECRET_NATIVE_REF SECRET_CALL SECRET_TURN native_ref call_id turn_id) do
      refute Jason.encode!(api) =~ secret
      refute output =~ secret
    end

    GenServer.stop(store)
  end

  test "public label and payload marker reflect stored facts without changing v1 persistence" do
    {:ok, legacy} = DecisionValidation.normalize(%{question: "Choose?", blocking: false}, ticket: %{identifier: "123"})
    persisted = DecisionProjection.to_json_safe(legacy)

    for fields <- [%{requester: %{kind: :worker}}, %{origin: :attention}, %{native: %{harness: :claude, hold: :deferred}}, %{questions: [%{id: "q"}]}, %{short_label: "Explicit label"}] do
      attributed = struct!(legacy, fields)
      assert PublicProjection.encode(attributed)["payload_version"] == 2
      assert DecisionProjection.to_json_safe(attributed) == persisted
    end

    assert Projection.public_v2(%{legacy | short_label: "Explicit label"}).short_label == "Explicit label"
    assert Projection.public_v2(%{legacy | legacy_attention: %{slug: "legacy"}}).origin == "attention"
    assert Projection.public_v2(legacy).short_label == nil
  end

  test "read API encoder matches the command v2 golden fixture" do
    {:ok, now, 0} = @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("created_at") |> DateTime.from_iso8601()
    {:ok, decision} = DecisionValidation.normalize(%{question: "Choose scope?", blocking: false, context: %{short_summary: "Scope"}}, ticket: %{identifier: "123"}, now: now)
    {:ok, fact} = DecisionEvent.new(:request_attributed, decision.decision_id, 1, %{requester: %{kind: :executor, executor_id: "operator"}, origin: :executor_cli}, event_id: "golden", run_id: "test")
    {:ok, decision} = Projection.apply(decision, fact)
    encoded = PublicProjection.encode(%{decision | decision_id: "dec_golden"})
    if System.get_env("AIUR_UPDATE_GOLDEN") == "1", do: File.write!(@fixture, Jason.encode!(encoded, pretty: true) <> "\n")
    assert encoded == @fixture |> File.read!() |> Jason.decode!()
  end

  defp controller_conn(store) do
    conn(:get, "/api/v1/decisions")
    |> put_private(:decision_api, DecisionApi)
    |> put_private(:decision_api_opts, store: store)
  end
end
