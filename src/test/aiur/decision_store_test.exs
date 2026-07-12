defmodule Aiur.DecisionStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.{DecisionPubSub, DecisionStore}
  alias Aiur.Events.Exchange

  @ticket %{identifier: "979", title: "OCC-1", url: "https://github.com/its-everdred/aiur/issues/979"}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Path.join(System.tmp_dir!(), "aiur-decision-store-#{System.unique_integer([:positive])}")
    Application.put_env(:aiur, :decision_state_dir, dir)

    on_exit(fn ->
      case original_override do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp start_store!(dir, opts \\ []) do
    Application.put_env(:aiur, :decision_state_dir, dir)

    start_opts =
      Keyword.merge([name: nil, filesystem_sync_fun: fn -> :ok end], opts)

    {:ok, pid} = DecisionStore.start_link(start_opts)
    pid
  end

  defp request(pid, payload, opts \\ []) do
    DecisionStore.request(payload, Keyword.merge([ticket: @ticket, source: @source], opts), pid)
  end

  defp project_attention(pid, payload, opts \\ []) do
    DecisionStore.project_attention(
      payload,
      Keyword.merge([ticket: @ticket, source: @source, legacy_attention: legacy_attention()], opts),
      pid
    )
  end

  defp enrich_attention(pid, payload, opts) do
    DecisionStore.enrich_attention(
      payload,
      Keyword.merge([ticket: @ticket, source: @source, legacy_attention: legacy_attention()], opts),
      pid
    )
  end

  defp legacy_attention do
    %{
      slug: "scope-question",
      topic: "ticket.979.agent.attention.scope-question"
    }
  end

  defp minimal_attention(question \\ "Which scope should own this?") do
    %{
      "question" => question,
      "blocking" => true,
      "kind" => "legacy_attention",
      "source_id" => "legacy_attention:scope-question"
    }
  end

  describe "happy path" do
    test "accepts a fresh request as version 1", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{status: :accepted, decision: decision}} =
               request(pid, %{"question" => "Deploy now?", "blocking" => true})

      assert decision.version == 1
      assert {:ok, ^decision} = DecisionStore.get(decision.decision_id, pid)
      assert DecisionStore.list(pid) == [decision]
      assert {:ok, [^decision]} = DecisionStore.history(decision.decision_id, pid)
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
      refute_receive :filesystem_synced

      assert {:ok, _} = request(pid, %{"question" => "Deploy now?", "blocking" => true})
      refute_receive :filesystem_synced
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

    test "the next version with different content is accepted as an enrichment", %{dir: dir} do
      pid = start_store!(dir)
      base = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}

      assert {:ok, %{status: :accepted, decision: v1}} = request(pid, base)

      v2_payload = Map.merge(base, %{"question" => "Deploy now, revised?", "version" => 2})
      assert {:ok, %{status: :accepted, decision: v2}} = request(pid, v2_payload)

      assert v2.decision_id == v1.decision_id
      assert v2.version == 2
      assert {:ok, [^v1, ^v2]} = DecisionStore.history(v1.decision_id, pid)
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

  describe "legacy attention projection and enrichment" do
    test "a minimal attention creates one custom-response-only Decision", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{status: :accepted, decision: decision}} =
               project_attention(pid, minimal_attention())

      assert decision.version == 1
      assert decision.blocking
      assert decision.kind == "legacy_attention"
      assert decision.options == []
      assert decision.legacy_attention == legacy_attention()
      assert DecisionStore.list(pid) == [decision]
      assert {:ok, [^decision]} = DecisionStore.history(decision.decision_id, pid)
    end

    test "a structured request enriches the same Decision and exact retries do not append", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{status: :accepted, decision: v1}} =
               project_attention(pid, minimal_attention())

      structured = %{
        "question" => "Which scope should own this?",
        "blocking" => true,
        "kind" => "architecture",
        "source_id" => "legacy_attention:scope-question",
        "context" => %{"short_summary" => "Two owners are viable."},
        "options" => [
          %{"id" => "facade", "label" => "Facade"},
          %{"id" => "runtime", "label" => "Runtime"}
        ],
        "recommendation" => %{"option_id" => "runtime", "reason" => "Owns the state."}
      }

      source_v2 = %{agent_id: "agent-1", session_id: "session-1", event_id: "call-2"}

      assert {:ok, %{status: :accepted, decision: v2}} =
               enrich_attention(pid, structured, source: source_v2)

      assert v2.decision_id == v1.decision_id
      assert v2.version == 2
      assert length(v2.options) == 2
      assert DecisionStore.list(pid) == [v2]

      assert {:ok, %{status: :duplicate, decision: ^v2}} =
               enrich_attention(pid, structured, source: source_v2)

      assert {:ok, [^v1, ^v2]} = DecisionStore.history(v1.decision_id, pid)
    end

    test "a retried structured action deduplicates after a later version advances", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: v1}} = project_attention(pid, minimal_attention())

      v2_payload =
        minimal_attention()
        |> Map.put("kind", "architecture")
        |> Map.put("context", %{"short_summary" => "First enrichment"})

      source_v2 = %{agent_id: "agent-1", session_id: "session-1", event_id: "call-2"}
      assert {:ok, %{status: :accepted, decision: v2}} = enrich_attention(pid, v2_payload, source: source_v2)

      v3_payload = Map.put(v2_payload, "context", %{"short_summary" => "Second enrichment"})
      source_v3 = %{agent_id: "agent-1", session_id: "session-1", event_id: "call-3"}
      assert {:ok, %{status: :accepted, decision: v3}} = enrich_attention(pid, v3_payload, source: source_v3)

      assert {:ok, %{status: :duplicate, decision: ^v2}} =
               enrich_attention(pid, v2_payload, source: source_v2)

      assert {:ok, ^v3} = DecisionStore.get(v1.decision_id, pid)
      assert {:ok, [^v1, ^v2, ^v3]} = DecisionStore.history(v1.decision_id, pid)
    end

    test "the same protocol call id in a new session is a distinct enrichment action", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{decision: v1}} = project_attention(pid, minimal_attention())

      first =
        minimal_attention()
        |> Map.put("kind", "architecture")
        |> Map.put("context", %{"short_summary" => "First session"})

      assert {:ok, %{status: :accepted, decision: v2}} =
               enrich_attention(pid, first, source: %{agent_id: "agent-1", session_id: "session-a", event_id: "call-2"})

      second = Map.put(first, "context", %{"short_summary" => "Second session"})

      assert {:ok, %{status: :accepted, decision: v3}} =
               enrich_attention(pid, second, source: %{agent_id: "agent-1", session_id: "session-b", event_id: "call-2"})

      assert v3.version == 3
      assert {:ok, [^v1, ^v2, ^v3]} = DecisionStore.history(v1.decision_id, pid)
    end

    test "a retried legacy action deduplicates after structured enrichment", %{dir: dir} do
      pid = start_store!(dir)
      legacy_source = %{agent_id: "agent-1", session_id: "session-1", event_id: "call-legacy"}

      assert {:ok, %{status: :accepted, decision: v1}} =
               project_attention(pid, minimal_attention(), source: legacy_source)

      structured = Map.put(minimal_attention(), "kind", "architecture")

      assert {:ok, %{status: :accepted, decision: v2}} =
               enrich_attention(pid, structured, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-enrich"})

      assert {:ok, %{status: :duplicate, decision: ^v1}} =
               project_attention(pid, minimal_attention(), source: legacy_source)

      assert {:ok, ^v2} = DecisionStore.get(v1.decision_id, pid)
      assert {:ok, [^v1, ^v2]} = DecisionStore.history(v1.decision_id, pid)
    end

    test "equivalent enrichment content from a distinct action remains a duplicate", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{decision: v1}} = project_attention(pid, minimal_attention())

      structured = Map.put(minimal_attention(), "kind", "architecture")

      assert {:ok, %{status: :accepted, decision: v2}} =
               enrich_attention(pid, structured, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-2"})

      assert {:ok, %{status: :duplicate, decision: ^v2}} =
               enrich_attention(pid, structured, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-distinct"})

      assert {:ok, [^v1, ^v2]} = DecisionStore.history(v1.decision_id, pid)
    end

    test "an explicit stale version is rejected even when enrichment content is unchanged", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{decision: v1}} = project_attention(pid, minimal_attention())

      structured = Map.put(minimal_attention(), "kind", "architecture")

      assert {:ok, %{decision: v2}} =
               enrich_attention(pid, structured, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-2"})

      stale = Map.put(structured, "version", 1)

      assert {:error, {:conflict, {:stale_version, 1, 2}}} =
               enrich_attention(pid, stale, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-distinct"})

      assert {:ok, ^v2} = DecisionStore.get(v1.decision_id, pid)
      assert {:ok, [^v1, ^v2]} = DecisionStore.history(v1.decision_id, pid)
    end

    test "a changed minimal question preserves structured enrichment fields", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{decision: v1}} = project_attention(pid, minimal_attention())

      structured =
        minimal_attention()
        |> Map.put("kind", "architecture")
        |> Map.put("options", [%{"id" => "runtime", "label" => "Runtime"}])

      assert {:ok, %{decision: v2}} =
               enrich_attention(pid, structured, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-2"})

      assert {:ok, %{status: :accepted, decision: v3}} =
               project_attention(pid, minimal_attention("Which owner should take this now?"))

      assert v3.decision_id == v1.decision_id
      assert v3.version == 3
      assert v3.question == "Which owner should take this now?"
      assert v3.kind == v2.kind
      assert v3.options == v2.options
    end

    test "enrichment and later reminders preserve the original alert timestamp", %{dir: dir} do
      pid = start_store!(dir)

      minimal = Map.put(minimal_attention(), "created_at", "2026-07-12T01:00:00Z")
      assert {:ok, %{decision: v1}} = project_attention(pid, minimal)

      structured =
        minimal_attention()
        |> Map.put("kind", "architecture")
        |> Map.put("context", %{"short_summary" => "Structured context"})

      assert {:ok, %{decision: v2}} =
               enrich_attention(pid, structured, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-enrich"})

      assert {:ok, %{decision: v3}} =
               project_attention(pid, minimal_attention("Which owner now?"))

      assert v1.source_created_at == ~U[2026-07-12 01:00:00Z]
      assert v2.source_created_at == v1.source_created_at
      assert v3.source_created_at == v1.source_created_at
    end

    test "an enrichment without an existing legacy attention fails closed", %{dir: dir} do
      pid = start_store!(dir)

      assert {:error, {:legacy_attention, :not_found}} =
               enrich_attention(pid, minimal_attention(), source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-2"})

      assert DecisionStore.list(pid) == []
    end

    test "legacy history and provenance survive restart", %{dir: dir} do
      pid1 = start_store!(dir)
      assert {:ok, %{decision: v1}} = project_attention(pid1, minimal_attention())

      assert {:ok, %{decision: v2}} =
               enrich_attention(pid1, Map.put(minimal_attention(), "kind", "architecture"), source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-2"})

      GenServer.stop(pid1)
      pid2 = start_store!(dir)

      assert DecisionStore.health(pid2) == :writable
      assert {:ok, ^v2} = DecisionStore.get(v1.decision_id, pid2)
      assert {:ok, [^v1, ^v2]} = DecisionStore.history(v1.decision_id, pid2)
    end
  end

  describe "validation failures persist nothing" do
    test "an invalid payload is rejected without any append", %{dir: dir} do
      pid = start_store!(dir)
      assert {:error, {:decision_invalid, {:question, :missing}}} = request(pid, %{"blocking" => true})
      assert DecisionStore.list(pid) == []
    end
  end

  describe "restart recovery" do
    test "a fresh store instance replays durable state from the same path", %{dir: dir} do
      pid1 = start_store!(dir)
      payload = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, %{status: :accepted, decision: accepted}} = request(pid1, payload)
      GenServer.stop(pid1)

      pid2 = start_store!(dir)
      assert {:ok, replayed} = DecisionStore.get(accepted.decision_id, pid2)
      assert replayed.question == accepted.question
      assert replayed.content_hash == accepted.content_hash
      assert DecisionStore.health(pid2) == :writable
    end

    test "a decision with an artifact survives restart without being flagged as corrupt", %{dir: dir} do
      pid1 = start_store!(dir)

      payload = %{
        "question" => "Deploy now?",
        "blocking" => true,
        "source_id" => "retry-1",
        "artifacts" => ["https://github.com/its-everdred/aiur"]
      }

      assert {:ok, %{status: :accepted, decision: accepted}} = request(pid1, payload)
      assert [%{kind: :url}] = accepted.artifacts
      GenServer.stop(pid1)

      pid2 = start_store!(dir)
      assert DecisionStore.health(pid2) == :writable
      assert {:ok, replayed} = DecisionStore.get(accepted.decision_id, pid2)
      assert replayed.artifacts == accepted.artifacts
    end
  end

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
      assert {:repair, _reason} = DecisionStore.health(pid)
    end
  end

  describe "notification" do
    test "an accepted request fans out through Exchange under its reserved event id and broadcasts on PubSub",
         %{dir: dir} do
      pid = start_store!(dir)
      :ok = Exchange.subscribe("ticket.979.agent.decision.requested")
      :ok = DecisionPubSub.subscribe()

      payload = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, %{status: :accepted, decision: decision}} = request(pid, payload)

      assert_receive {:event, %{:topic => "ticket.979.agent.decision.requested", "question" => "Deploy now?"}}, 500
      assert_receive {:decision_changed, decision_id, 1}, 500
      assert decision_id == decision.decision_id
    end

    test "a duplicate does not fan out again", %{dir: dir} do
      pid = start_store!(dir)
      payload = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, _} = request(pid, payload)

      :ok = Exchange.subscribe("ticket.979.agent.decision.requested")
      assert {:ok, %{status: :duplicate}} = request(pid, payload)
      refute_receive {:event, %{topic: "ticket.979.agent.decision.requested"}}, 200
    end
  end
end
