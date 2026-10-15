Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.RequestsTest do
  use Aiur.DecisionStoreCase, async: false

  describe "happy path" do
    test "accepts a fresh request as version 1", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{status: :accepted, decision: decision}} =
               request(pid, %{"question" => "Deploy now?", "blocking" => true})

      assert decision.version == 1
      assert {:ok, ^decision} = DecisionStore.get(decision.decision_id, pid)
      assert DecisionStore.list(pid) == [decision]
      assert {:ok, [^decision]} = DecisionStore.history(decision.decision_id, pid)
      assert DecisionStore.all_history(pid) == %{decision.decision_id => [decision]}

      assert {:ok, [%DecisionEvent{type: :requested, data: ^decision}]} =
               DecisionStore.audit_history(decision.decision_id, pid)
    end

    test "returns a bounded recent audit window with only its projection contexts", %{dir: dir} do
      pid = start_store!(dir, dispatch_delay_ms: 60_000)

      assert {:ok, %{decision: contextual}} =
               request(pid, %{
                 "source_id" => "recent-audit-context",
                 "question" => "Does a bounded lifecycle event retain its context?",
                 "blocking" => true,
                 "options" => [%{"id" => "yes", "label" => "Yes"}]
               })

      for index <- 1..55 do
        assert {:ok, _result} =
                 request(pid, %{
                   "source_id" => "recent-audit-#{index}",
                   "question" => "Recent decision #{index}?",
                   "blocking" => false
                 })
      end

      assert %{records: records, contexts: contexts, revisions: %{}} =
               DecisionStore.recent_audit_history(5, pid)

      assert Enum.map(records, & &1.data.source_id) ==
               Enum.map(55..51//-1, &"recent-audit-#{&1}")

      assert map_size(contexts) == 5
      assert %{records: capped} = DecisionStore.recent_audit_history(500, pid)
      assert length(capped) == 50
      assert Enum.any?(DecisionStore.recent_decisions(50, pid), &(&1.decision_id == contextual.decision_id))

      assert {:ok, _answer_result} =
               answer(pid, contextual.decision_id, %{
                 "idempotency_key" => "recent-audit-answer",
                 "expected_version" => contextual.version,
                 "option_id" => "yes"
               })

      assert [answered] = DecisionHistory.list(server: pid, limit: 1)
      assert answered.change == :answered
      assert answered.question == "Does a bounded lifecycle event retain its context?"

      GenServer.stop(pid)
      replayed = start_store!(dir, dispatch_delay_ms: 60_000)
      assert [replayed_answer] = DecisionHistory.list(server: replayed, limit: 1)
      assert replayed_answer.question == answered.question
    end

    test "new request audit records carry the typed envelope and canonical run id", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{decision: decision}} = request(pid, %{"question" => "Deploy now?", "blocking" => true})

      [record] =
        dir
        |> Path.join("decisions.ndjson")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert record["event_type"] == "requested"
      assert record["run_id"] == Boot.run_id()
      assert "decision-provenance-v1:" <> reserved_event_id = record["event_id"]
      assert {reserved_id, ""} = Integer.parse(reserved_event_id)
      assert reserved_id > 0
      assert record["data"]["decision_id"] == decision.decision_id
    end

    test "the audit log and the projection file are both owner-only after an accept", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, _} = request(pid, %{"question" => "Deploy now?", "blocking" => true})

      for filename <- ["decisions.ndjson", "decisions.json"] do
        %File.Stat{mode: mode} = File.stat!(Path.join(dir, filename))
        assert Bitwise.band(mode, 0o777) == 0o600
      end
    end

    test "runs the filesystem barrier during startup rather than the first request", %{dir: dir} do
      test_pid = self()

      sync_fun = fn ->
        send(test_pid, :filesystem_synced)
        :ok
      end

      pid = start_store!(dir, filesystem_sync_fun: sync_fun)

      assert_receive :filesystem_synced, 2_000
      refute_receive :filesystem_synced, 100

      assert {:ok, _} = request(pid, %{"question" => "Deploy now?", "blocking" => true})
      refute_receive :filesystem_synced, 100
    end

    test "redacts ticket and artifact credentials before either durable file is written", %{dir: dir} do
      pid = start_store!(dir)
      secret = "GHSAT0" <> String.duplicate("A", 36)

      ticket = %{
        identifier: "979",
        title: "Leaked #{secret}",
        url: "https://github.com/its-everdred/aiur/issues/979?token=#{secret}"
      }

      payload = %{
        "question" => "Inspect the artifact?",
        "blocking" => true,
        "artifacts" => ["https://raw.githubusercontent.com/org/repo/main/file?token=#{secret}"]
      }

      assert {:ok, %{status: :accepted}} = request(pid, payload, ticket: ticket)

      for filename <- ["decisions.ndjson", "decisions.json"] do
        persisted = File.read!(Path.join(dir, filename))
        refute persisted =~ secret
        assert persisted =~ "[REDACTED:ghsat]"
      end
    end

    test "an unknown decision_id returns :not_found", %{dir: dir} do
      pid = start_store!(dir)
      assert {:error, :not_found} = DecisionStore.get("dec_missing", pid)
      assert {:error, :not_found} = DecisionStore.history("dec_missing", pid)
    end
  end

  describe "dedup and versioning" do
    test "an exact replay of the current version and content is a duplicate, not a new append", %{dir: dir} do
      pid = start_store!(dir)
      payload = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}

      assert {:ok, %{status: :accepted, decision: first}} = request(pid, payload)
      assert {:ok, %{status: :duplicate, decision: second}} = request(pid, payload)

      assert first.decision_id == second.decision_id
      assert {:ok, [^first]} = DecisionStore.history(first.decision_id, pid)
    end

    test "changed content re-arms a dismissed Command that is not a legacy attention", %{dir: dir} do
      pid = start_store!(dir)
      base = %{"question" => "Roll the index?", "blocking" => false, "source_id" => "rearm-1"}

      assert {:ok, %{decision: v1}} = request(pid, base)
      refute v1.legacy_attention

      assert {:ok, %{decision: dismissed}} =
               DecisionStore.dismiss(v1.decision_id, [actor: %{kind: :operator, id: "dashboard"}], pid)

      assert dismissed.decision_status == :dismissed

      # The operator closed this against evidence that no longer exists, so the
      # re-file must bring it back — the same guarantee a legacy attention gets.
      assert {:ok, %{decision: rearmed}} =
               request(pid, Map.merge(base, %{"question" => "Roll the index after the backfill?", "version" => 2}))

      assert rearmed.decision_id == v1.decision_id
      assert rearmed.decision_status == :open
      assert rearmed.delivery_status == :not_dispatched
    end

    test "the next version with different content is accepted as an enrichment", %{dir: dir} do
      pid = start_store!(dir)
      base = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}

      assert {:ok, %{status: :accepted, decision: v1}} = request(pid, base)

      v2_payload = Map.merge(base, %{"question" => "Deploy now, revised?", "version" => 2})
      assert {:ok, %{status: :accepted, decision: v2}} = request(pid, v2_payload)

      assert v2.decision_id == v1.decision_id
      assert v2.version == 2
      assert {:ok, [^v1, ^v2]} = DecisionStore.history(v1.decision_id, pid)
      assert DecisionStore.all_history(pid)[v1.decision_id] == [v1, v2]
      assert {:ok, ^v2} = DecisionStore.get(v1.decision_id, pid)
    end

    test "same version, different content is an idempotency conflict", %{dir: dir} do
      pid = start_store!(dir)
      base = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, _} = request(pid, base)

      conflicting = Map.put(base, "question", "Deploy now, but different?")
      assert {:error, {:conflict, {:idempotency_conflict, 1}}} = request(pid, conflicting)
    end

    test "a stale version is rejected", %{dir: dir} do
      pid = start_store!(dir)
      base = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, _} = request(pid, base)
      assert {:ok, _} = request(pid, Map.merge(base, %{"question" => "v2", "version" => 2}))

      stale = Map.merge(base, %{"question" => "v1 again", "version" => 1})
      assert {:error, {:conflict, {:stale_version, 1, 2}}} = request(pid, stale)

      way_stale = Map.merge(base, %{"question" => "v0?", "version" => 0})
      assert {:error, {:version, :invalid_type}} = request(pid, way_stale)
    end

    test "a version gap is rejected", %{dir: dir} do
      pid = start_store!(dir)
      base = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, _} = request(pid, base)

      gapped = Map.merge(base, %{"question" => "v3?", "version" => 3})
      assert {:error, {:conflict, {:version_gap, 3, 1}}} = request(pid, gapped)
    end

    test "a fresh decision_id requested at a version other than 1 is a version gap", %{dir: dir} do
      pid = start_store!(dir)
      payload = %{"question" => "Q?", "blocking" => true, "version" => 2}
      assert {:error, {:conflict, {:version_gap, 2, nil}}} = request(pid, payload)
    end
  end

  describe "validation failures persist nothing" do
    test "an invalid payload is rejected without any append", %{dir: dir} do
      pid = start_store!(dir)
      assert {:error, {:decision_invalid, {:question, :missing}}} = request(pid, %{"blocking" => true})
      assert DecisionStore.list(pid) == []
    end
  end
end
