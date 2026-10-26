Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.CorruptionTest do
  use Aiur.DecisionStoreCase, async: false

  describe "corruption" do
    test "an interior-corrupt audit log boots read-only and keeps validated-prefix reads", %{dir: dir} do
      pid1 = start_store!(dir)
      payload = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, %{status: :accepted, decision: accepted}} = request(pid1, payload)
      GenServer.stop(pid1)

      ndjson_path = Path.join(dir, "decisions.ndjson")
      File.write!(ndjson_path, "not json at all\n", [:append])

      pid2 = start_store!(dir)
      assert {:corrupt, 2, _reason} = DecisionStore.health(pid2)
      assert {:ok, ^accepted} = DecisionStore.get(accepted.decision_id, pid2)
      assert {:error, {:store_unavailable, {:corrupt, 2, _reason}}} = request(pid2, payload)
    end

    test "an unrecognised but well-formed event type replays writable and is not lost", %{dir: dir} do
      pid1 = start_store!(dir, dispatch_delay_ms: 60_000)

      assert {:ok, %{decision: decision}} =
               request(pid1, %{
                 "question" => "Survive a rollback?",
                 "blocking" => true,
                 "options" => [%{"id" => "yes", "label" => "Yes"}]
               })

      GenServer.stop(pid1)

      # Exactly the shape a newer binary writes: a complete envelope whose
      # event_type this build has never heard of.
      path = Path.join(dir, "decisions.ndjson")

      future_event = %{
        "schema_version" => 1,
        "event_type" => "some_future_event",
        "event_id" => "evt-from-a-newer-build",
        "run_id" => "run-newer-build",
        "decision_id" => decision.decision_id,
        "decision_version" => decision.version,
        "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "data" => %{"whatever" => "a shape this build cannot interpret"},
        "content_hash" => "hash-this-build-cannot-recompute"
      }

      :ok = Journal.append(path, future_event)

      pid2 = start_store!(dir, dispatch_delay_ms: 60_000)

      # Version skew is not corruption: the store stays writable, so the
      # operator can still answer Commands.
      assert DecisionStore.health(pid2) == :writable
      assert {:ok, replayed} = DecisionStore.get(decision.decision_id, pid2)
      assert replayed.decision_status == :open

      assert {:ok, %{status: :accepted}} =
               answer(pid2, decision.decision_id, %{
                 "idempotency_key" => "operator-after-skew",
                 "expected_version" => decision.version,
                 "option_id" => "yes"
               })

      assert {:ok, %{status: :accepted}} =
               request(pid2, %{"question" => "Still accepting new Commands?", "blocking" => false})

      # The unrecognised record is skipped for projection but never dropped, so
      # rolling forward again still sees it.
      assert path |> File.read!() |> String.contains?("some_future_event")

      GenServer.stop(pid2)
      pid3 = start_store!(dir, dispatch_delay_ms: 60_000)
      assert DecisionStore.health(pid3) == :writable

      assert {:ok, records, nil} = Journal.replay(path, &DecisionProjection.decode_record/1)

      assert [%Unrecognized{event_type: "some_future_event", event_id: "evt-from-a-newer-build"} = retained] =
               Enum.filter(records, &match?(%Unrecognized{}, &1))

      assert retained.decision_id == decision.decision_id
      assert retained.raw["data"] == %{"whatever" => "a shape this build cannot interpret"}
    end

    test "a malformed record stays fail-closed even when its event type is unrecognised", %{dir: dir} do
      # Same unknown type, but the envelope this build *can* check is broken.
      # Forward compatibility must not become a hole that swallows damage.
      broken = [
        {"a missing decision_id", %{"decision_id" => nil}},
        {"a non-positive decision_version", %{"decision_version" => 0}},
        {"an unparseable occurred_at", %{"occurred_at" => "not-a-timestamp"}},
        {"a missing event_id", %{"event_id" => nil}},
        {"a non-map data payload", %{"data" => "not a map"}},
        {"a missing content_hash", %{"content_hash" => ""}},
        {"a missing run_id", %{"run_id" => nil}}
      ]

      for {label, override} <- broken do
        case_dir = Path.join(dir, "broken-#{System.unique_integer([:positive])}")
        pid1 = start_store!(case_dir)
        assert {:ok, %{decision: decision}} = request(pid1, %{"question" => "Reject #{label}?", "blocking" => true})
        GenServer.stop(pid1)

        record =
          Map.merge(
            %{
              "schema_version" => 1,
              "event_type" => "some_future_event",
              "event_id" => "evt-broken",
              "run_id" => "run-broken",
              "decision_id" => decision.decision_id,
              "decision_version" => decision.version,
              "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
              "data" => %{},
              "content_hash" => "hash"
            },
            override
          )

        :ok = Journal.append(Path.join(case_dir, "decisions.ndjson"), record)

        pid2 = start_store!(case_dir)
        assert {:corrupt, 2, _reason} = DecisionStore.health(pid2), "#{label} must stay fail-closed"
        GenServer.stop(pid2)
      end
    end

    test "a valid envelope with an illegal lifecycle transition makes replay read-only", %{dir: dir} do
      pid1 = start_store!(dir)
      assert {:ok, %{decision: decision}} = request(pid1, %{"question" => "Deploy now?", "blocking" => true})
      GenServer.stop(pid1)

      {:ok, invalid} =
        DecisionEvent.new(
          :delivered,
          decision.decision_id,
          decision.version,
          %{action_id: "act_missing", attempt_id: "attempt-1", queue_item_id: 7},
          event_id: "evt-illegal-transition",
          run_id: "run-replay-test"
        )

      :ok = Journal.append(Path.join(dir, "decisions.ndjson"), DecisionEvent.to_json_safe(invalid))
      File.write!(Path.join(dir, "decisions.ndjson"), "not json at all\n", [:append])

      pid2 = start_store!(dir)
      assert {:corrupt, 2, {:invalid_transition, :answer_missing}} = DecisionStore.health(pid2)
      assert {:ok, replayed} = DecisionStore.get(decision.decision_id, pid2)
      assert replayed.decision_status == :open
    end

    test "an incomplete final lifecycle envelope is truncated and leaves the durable prefix writable", %{dir: dir} do
      pid1 = start_store!(dir)
      assert {:ok, %{decision: decision}} = request(pid1, %{"question" => "Deploy now?", "blocking" => true})
      GenServer.stop(pid1)

      path = Path.join(dir, "decisions.ndjson")
      File.write!(path, ~s({"event_type":"answer_recorded","decision_id":"#{decision.decision_id}"), [:append])

      pid2 = start_store!(dir)
      assert DecisionStore.health(pid2) == :writable
      assert {:ok, ^decision} = DecisionStore.get(decision.decision_id, pid2)
      assert length(String.split(File.read!(path), "\n", trim: true)) == 1
    end
  end

  describe "repair mode" do
    test "a projection write failure during an accept logs and alerts, not just flips health silently", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{status: :accepted}} = request(pid, %{"question" => "Q1?", "blocking" => true})

      # Make the projection's directory unwritable so its NEXT atomic write
      # (temp-file create + rename) fails, without touching the audit log.
      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod!(dir, 0o700) end)

      log =
        capture_log(fn ->
          assert {:ok, %{status: :accepted}} =
                   request(pid, %{"question" => "Q2?", "blocking" => true, "source_id" => "other"})
        end)

      assert log =~ "aiur_decision_store phase=projection_repair_failed"
      assert {:projection_stale, %DateTime{}} = DecisionStore.health(pid)
    end
  end
end
