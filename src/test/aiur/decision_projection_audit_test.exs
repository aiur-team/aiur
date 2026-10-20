defmodule Aiur.DecisionProjectionAuditTest do
  use ExUnit.Case, async: true

  alias Aiur.{Decision, DecisionAnswer, DecisionEvent, DecisionProjection, DecisionValidation}

  alias Aiur.DecisionEvent.Unrecognized

  @ticket %{identifier: "979", title: "OCC-1", url: "https://github.com/its-everdred/aiur/issues/979"}

  @source %{agent_id: "agent-1", session_id: "session-1", event_id: "evt-1"}

  defp build_decision(payload_overrides \\ %{}, opts \\ []) do
    payload = Map.merge(%{"question" => "Deploy now?", "blocking" => true}, payload_overrides)
    {:ok, decision} = DecisionValidation.normalize(payload, Keyword.merge([ticket: @ticket, source: @source], opts))
    decision
  end

  # Simulates the exact bytes that would be on disk: encode through
  # to_json_safe/1, then Jason round-trip so every value is the plain
  # string-keyed map decode_record/1 actually receives from Journal.
  defp persisted_raw(decision) do
    decision |> DecisionProjection.to_json_safe() |> Jason.encode!() |> Jason.decode!()
  end

  defp answer(decision, overrides \\ %{}) do
    payload =
      Map.merge(
        %{
          "idempotency_key" => "operator-answer-1",
          "expected_version" => decision.version,
          "option_id" => "ship"
        },
        overrides
      )

    {:ok, answer} =
      DecisionAnswer.normalize(payload,
        decision_id: decision.decision_id,
        decision_version: decision.version,
        options: decision.options,
        actor: %{kind: :operator, id: "operator-1"},
        now: ~U[2026-07-12 10:01:00Z]
      )

    answer
  end

  defp event(type, decision, data, sequence) do
    {:ok, event} =
      DecisionEvent.new(type, decision.decision_id, decision.version, data,
        event_id: "evt-#{sequence}",
        run_id: "run-1",
        now: DateTime.add(~U[2026-07-12 10:00:00Z], sequence, :second)
      )

    event
  end

  defp future_raw(request, overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => 1,
        "event_type" => "some_future_event",
        "event_id" => "evt-future-1",
        "run_id" => "run-future",
        "decision_id" => request.decision_id,
        "decision_version" => request.version,
        "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "data" => %{"payload" => "unknown shape"},
        "content_hash" => "hash-from-a-newer-build"
      },
      overrides
    )
  end

  describe "typed audit records" do
    test "decode rejects a lifecycle record whose content hash changed" do
      request =
        build_decision(%{
          "source_id" => "hash-1",
          "options" => [%{"id" => "ship", "label" => "Ship it"}]
        })

      accepted = answer(request)
      lifecycle = event(:answer_recorded, request, accepted, 1)

      raw = lifecycle |> DecisionEvent.to_json_safe() |> Map.put("run_id", "tampered-run")

      assert DecisionProjection.decode_record(raw) == {:error, :event_content_hash_mismatch}
    end

    test "decode rejects an unsupported lifecycle schema version" do
      request =
        build_decision(%{
          "source_id" => "schema-version-1",
          "options" => [%{"id" => "ship", "label" => "Ship it"}]
        })

      lifecycle = event(:answer_recorded, request, answer(request), 1)
      raw = lifecycle |> DecisionEvent.to_json_safe() |> Map.put("schema_version", 2)

      assert DecisionProjection.decode_record(raw) == {:error, {:schema_version, :unsupported}}
    end

    test "an OCC-1 record without a discriminator still decodes as a legacy Decision" do
      decision = build_decision(%{"source_id" => "legacy-1"})

      assert {:ok, %Decision{} = decoded} = DecisionProjection.decode_record(persisted_raw(decision))
      assert decoded.decision_id == decision.decision_id
      assert decoded.decision_status == :open
      assert decoded.delivery_status == :not_dispatched
    end
  end

  describe "unrecognised event types" do
    test "decode retains an unknown type opaquely instead of reporting corruption" do
      request = build_decision(%{"source_id" => "future-1"})
      raw = future_raw(request)

      assert {:ok, %Unrecognized{} = retained} = DecisionProjection.decode_record(raw)
      assert retained.event_type == "some_future_event"
      assert retained.event_id == "evt-future-1"
      assert retained.decision_id == request.decision_id
      assert retained.decision_version == request.version
      # The exact decoded line is kept, so nothing is lost on the way through.
      assert retained.raw == raw
    end

    test "an unknown type tolerates a schema version this build does not know" do
      request =
        build_decision(%{"source_id" => "future-schema", "options" => [%{"id" => "ship", "label" => "Ship it"}]})

      assert {:ok, %Unrecognized{}} =
               DecisionProjection.decode_record(future_raw(request, %{"schema_version" => 99}))

      # A type we *do* know keeps failing closed on an unsupported version.
      lifecycle = event(:answer_recorded, request, answer(request), 1)
      raw = lifecycle |> DecisionEvent.to_json_safe() |> Map.put("schema_version", 99)
      assert DecisionProjection.decode_record(raw) == {:error, {:schema_version, :unsupported}}
    end

    test "decode still fails closed on a malformed envelope under an unknown type" do
      request = build_decision(%{"source_id" => "future-broken"})

      broken = [
        {%{"schema_version" => "one"}, {:schema_version, :invalid}},
        {%{"event_id" => nil}, {:event_id, :missing_or_invalid}},
        {%{"decision_id" => ""}, {:decision_id, :missing_or_invalid}},
        {%{"decision_version" => 0}, {:decision_version, :invalid}},
        {%{"run_id" => nil}, {:run_id, :missing_or_invalid}},
        {%{"occurred_at" => "yesterday"}, {:occurred_at, :invalid}},
        {%{"data" => ["not", "a", "map"]}, {:data, :invalid}},
        {%{"content_hash" => nil}, {:content_hash, :missing_or_invalid}}
      ]

      for {override, expected} <- broken do
        assert DecisionProjection.decode_record(future_raw(request, override)) == {:error, expected}
      end
    end

    test "a missing or non-string event_type is corruption, not forward compatibility" do
      request = build_decision(%{"source_id" => "future-typeless"})

      assert DecisionProjection.decode_record(future_raw(request, %{"event_type" => ""})) ==
               {:error, {:event_type, :unknown}}

      assert DecisionProjection.decode_record(future_raw(request, %{"event_type" => 7})) ==
               {:error, {:event_type, :missing_or_invalid}}
    end

    test "reduce_checked skips an unknown type without disturbing the projection" do
      request = build_decision(%{"source_id" => "future-reduce", "options" => [%{"id" => "ship", "label" => "Ship"}]})
      {:ok, unknown} = DecisionProjection.decode_record(future_raw(request))

      {baseline, nil} = DecisionProjection.reduce_checked([request])
      {with_unknown, corruption} = DecisionProjection.reduce_checked([request, unknown])

      assert corruption == nil
      assert with_unknown == baseline
    end

    test "reduce_checked still rejects a duplicated unknown event id" do
      request = build_decision(%{"source_id" => "future-duplicate"})
      {:ok, unknown} = DecisionProjection.decode_record(future_raw(request))

      assert {_projection, {:corrupt, 3, {:invalid_transition, :duplicate_event_id}}} =
               DecisionProjection.reduce_checked([request, unknown, unknown])
    end
  end

  describe "serialize_current/1" do
    test "produces the schema-versioned decisions list" do
      decision = build_decision()
      serialized = DecisionProjection.serialize_current(%{decision.decision_id => decision})

      assert serialized["schema_version"] == Decision.schema_version()
      assert [entry] = serialized["decisions"]
      assert entry["decision_id"] == decision.decision_id
      assert entry["authority"] == "supervisor_allowed"
    end
  end
end
