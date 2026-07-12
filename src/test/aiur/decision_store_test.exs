defmodule Aiur.DecisionStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.{AlertFeed, Boot, DecisionEvent, DecisionLog, DecisionPubSub, DecisionStore}
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

  defp answer(pid, decision_id, payload, opts \\ []) do
    DecisionStore.answer(
      decision_id,
      payload,
      Keyword.merge([actor: %{kind: :operator, id: "operator-1"}], opts),
      pid
    )
  end

  defp enrich(pid, decision_id, patch, expected_version, opts \\ []) do
    DecisionStore.enrich(
      decision_id,
      patch,
      Keyword.merge(
        [
          actor: %{kind: :supervisor, id: "supervising-agent"},
          expected_version: expected_version,
          now: ~U[2026-07-12 11:00:00Z]
        ],
        opts
      ),
      pid
    )
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
      assert DecisionStore.all_history(pid) == %{decision.decision_id => [decision]}

      assert {:ok, [%DecisionEvent{type: :requested, data: ^decision}]} =
               DecisionStore.audit_history(decision.decision_id, pid)
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
      assert is_integer(record["event_id"])
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

  describe "supervisor enrichment" do
    test "persists attributed enrichment before notification and survives restart", %{dir: dir} do
      pid1 = start_store!(dir)

      assert {:ok, %{decision: v1}} =
               request(pid1, %{
                 "question" => "Which architecture?",
                 "blocking" => true,
                 "source_id" => "supervisor-enrichment",
                 "kind" => "architecture",
                 "authority" => "supervisor_allowed",
                 "reversibility" => "reversible"
               })

      :ok = Exchange.subscribe("ticket.979.agent.decision.enriched")
      :ok = DecisionPubSub.subscribe()

      patch = %{"context" => %{"short_summary" => "Use the canonical store"}}

      assert {:ok, %{status: :accepted, decision: v2}} =
               enrich(pid1, v1.decision_id, patch, 1)

      assert v2.version == 2
      assert v2.created_at == v1.created_at
      assert v2.context.short_summary == "Use the canonical store"

      assert {:ok, [^v1, history_v2]} = DecisionStore.history(v1.decision_id, pid1)
      assert history_v2.version == 2

      assert {:ok, [requested, enriched]} = DecisionStore.audit_history(v1.decision_id, pid1)
      assert audit_type(requested) == :requested
      assert %DecisionEvent{type: :enriched, data: data} = enriched
      assert data.actor == %{kind: :supervisor, id: "supervising-agent"}
      assert data.expected_version == 1
      assert data.decision.version == 2

      assert_receive {:event, %{topic: "ticket.979.agent.decision.enriched"}}, 500
      assert_receive {:decision_changed, decision_id, 2}, 500
      assert decision_id == v1.decision_id

      persisted = File.read!(Path.join(dir, "decisions.ndjson"))
      assert persisted =~ ~s("event_type":"enriched")

      GenServer.stop(pid1)
      pid2 = start_store!(dir)
      assert DecisionStore.health(pid2) == :writable
      assert {:ok, replayed} = DecisionStore.get(v1.decision_id, pid2)
      assert replayed.version == 2
      assert replayed.context.short_summary == "Use the canonical store"
    end

    test "exact replay is duplicate while changed reuse conflicts without append or notification", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: v1}} =
               request(pid, %{
                 "question" => "Which architecture?",
                 "blocking" => true,
                 "source_id" => "supervisor-replay"
               })

      patch = %{"context" => %{"short_summary" => "Canonical"}}
      assert {:ok, %{status: :accepted, decision: accepted}} = enrich(pid, v1.decision_id, patch, 1)

      :ok = Exchange.subscribe("ticket.979.agent.decision.enriched")
      :ok = DecisionPubSub.subscribe()

      assert {:ok, %{status: :duplicate, decision: duplicate}} = enrich(pid, v1.decision_id, patch, 1)
      assert duplicate.version == accepted.version

      changed = %{"context" => %{"short_summary" => "Different"}}

      assert {:error, {:conflict, {:idempotency_conflict, 1}}} =
               enrich(pid, v1.decision_id, changed, 1)

      assert {:ok, audit} = DecisionStore.audit_history(v1.decision_id, pid)
      assert Enum.map(audit, &audit_type/1) == [:requested, :enriched]
      refute_receive {:event, %{topic: "ticket.979.agent.decision.enriched"}}, 100
      refute_receive {:decision_changed, _, _}, 100
      assert length(String.split(File.read!(Path.join(dir, "decisions.ndjson")), "\n", trim: true)) == 2
    end

    test "a stale historical base with no matching enrichment appends nothing", %{dir: dir} do
      pid = start_store!(dir)
      base = %{"question" => "Original?", "blocking" => true, "source_id" => "supervisor-stale"}
      assert {:ok, %{decision: v1}} = request(pid, base)

      assert {:ok, %{decision: v2}} =
               request(pid, Map.merge(base, %{"question" => "Updated?", "version" => 2}))

      assert {:error, {:conflict, {:stale_version, 1, 2}}} =
               enrich(pid, v1.decision_id, %{"context" => %{"short_summary" => "Stale"}}, 1)

      assert {:ok, ^v2} = DecisionStore.get(v1.decision_id, pid)
      assert {:ok, audit} = DecisionStore.audit_history(v1.decision_id, pid)
      assert Enum.map(audit, &audit_type/1) == [:requested, :requested]
    end

    test "enrichment after an answer preserves its lifecycle and never redispatches", %{dir: dir} do
      parent = self()

      dispatcher = fn _decision, _opts ->
        send(parent, :dispatched)
        {:ok, %{status: :accepted, item: %{id: 101}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: v1}} = request(pid, answerable_request("enrich-after-answer"))

      answer_payload = %{
        "idempotency_key" => "answer-before-enrichment",
        "expected_version" => 1,
        "option_id" => "ship"
      }

      assert {:ok, %{action: accepted}} = answer(pid, v1.decision_id, answer_payload)
      assert_receive :dispatched, 1_000
      settled = wait_for_decision(pid, v1.decision_id, &(&1.delivery_status == :queued))

      patch = %{"context" => %{"short_summary" => "Additional context"}}

      assert {:ok, %{status: :accepted, decision: enriched}} =
               enrich(
                 pid,
                 v1.decision_id,
                 patch,
                 1
               )

      assert enriched.version == 2
      assert enriched.answer == accepted
      assert enriched.delivery_status == :queued
      assert enriched.dispatch_attempts == settled.dispatch_attempts

      assert {:ok, %{status: :duplicate, decision: replayed}} =
               enrich(pid, v1.decision_id, patch, 1)

      assert replayed.answer == accepted
      assert replayed.delivery_status == :queued
      refute_receive :dispatched, 100
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

    test "a stale startup import cannot replace an enriched current question", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{decision: v1}} = project_attention(pid, minimal_attention("Original alert question?"))

      structured =
        minimal_attention("Current structured question?")
        |> Map.put("kind", "architecture")
        |> Map.put("context", %{"short_summary" => "The request was clarified."})

      assert {:ok, %{decision: v2}} =
               enrich_attention(pid, structured, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-enrich"})

      assert {:ok, %{status: :duplicate, decision: ^v2}} =
               project_attention(pid, minimal_attention("Original alert question?"), legacy_import: true)

      assert {:ok, ^v2} = DecisionStore.get(v1.decision_id, pid)
      assert {:ok, [^v1, ^v2]} = DecisionStore.history(v1.decision_id, pid)
    end

    test "changing legacy questions cannot grow one Decision beyond its configured bound", %{dir: dir} do
      pid = start_store!(dir, legacy_question_version_limit: 3)

      assert {:ok, %{decision: v1}} = project_attention(pid, minimal_attention("Question one?"))
      assert {:ok, %{decision: v2}} = project_attention(pid, minimal_attention("Question two?"))
      assert {:ok, %{decision: v3}} = project_attention(pid, minimal_attention("Question three?"))

      assert {:error, {:legacy_attention, {:version_limit, 3}}} =
               project_attention(pid, minimal_attention("Question four?"))

      assert {:ok, ^v3} = DecisionStore.get(v1.decision_id, pid)
      assert {:ok, [^v1, ^v2, ^v3]} = DecisionStore.history(v1.decision_id, pid)
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
      assert DecisionStore.all_history(pid2)[accepted.decision_id] == [replayed]
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

  describe "answer outbox" do
    test "persists the answer before dispatch and then records queue acceptance", %{dir: dir} do
      parent = self()

      dispatcher = fn decision, opts ->
        audit = DecisionStore.audit_history(decision.decision_id, opts[:store])
        send(parent, {:dispatch_observed, audit, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 41}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)

      assert {:ok, %{decision: decision}} =
               request(pid, %{
                 "question" => "Deploy now?",
                 "blocking" => true,
                 "source_id" => "answer-1",
                 "options" => [%{"id" => "ship", "label" => "Ship it"}]
               })

      :ok = Exchange.subscribe("ticket.979.agent.decision.answered")
      :ok = Exchange.subscribe("ticket.979.agent.decision.queued")
      :ok = DecisionPubSub.subscribe()

      payload = %{"idempotency_key" => "submit-1", "expected_version" => 1, "option_id" => "ship"}

      assert {:ok, %{status: :accepted, action: accepted, dispatch_status: :dispatch_pending}} =
               answer(pid, decision.decision_id, payload)

      assert_receive {:dispatch_observed, {:ok, audit}, attempt_id}, 1_000
      assert Enum.map(audit, &audit_type/1) == [:requested, :answer_recorded]
      assert String.starts_with?(attempt_id, accepted.action_id)

      settled = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      assert settled.answer == accepted
      assert [%{queue_item_id: 41, attempt_id: ^attempt_id, status: :queued}] = settled.dispatch_attempts
      assert_receive {:event, %{topic: "ticket.979.agent.decision.answered"}}, 500
      assert_receive {:event, %{topic: "ticket.979.agent.decision.queued"}}, 500
      assert_receive {:decision_changed, decision_id, 1}, 500
      assert decision_id == decision.decision_id
      assert_receive {:decision_changed, ^decision_id, 1}, 500
    end

    test "exact answer replay is duplicate while changed content under the action conflicts", %{dir: dir} do
      parent = self()

      dispatcher = fn _decision, _opts ->
        send(parent, :dispatched)
        {:ok, %{status: :accepted, item: %{id: 42}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-dedup"))

      payload = %{
        "idempotency_key" => "submit-1",
        "expected_version" => 1,
        "custom_response" => "Proceed carefully",
        "rationale" => "Checks passed"
      }

      assert {:ok, %{status: :accepted, action: accepted}} = answer(pid, decision.decision_id, payload)
      assert_receive :dispatched, 1_000
      _settled = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      assert {:ok, %{status: :duplicate, action: ^accepted}} = answer(pid, decision.decision_id, payload)
      refute_receive :dispatched, 100

      changed = Map.put(payload, "rationale", "Different rationale")

      assert {:error, {:conflict, {:idempotency_conflict, action_id}}} =
               answer(pid, decision.decision_id, changed)

      assert action_id == accepted.action_id
      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.count(audit, &(audit_type(&1) == :answer_recorded)) == 1
      assert Enum.count(audit, &(audit_type(&1) == :dispatch_queued)) == 1
    end

    test "concurrent distinct answers serialize to one winner", %{dir: dir} do
      dispatcher = fn _decision, _opts -> {:error, :no_running_agent} end
      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 20)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-race"))

      submissions = [
        %{"idempotency_key" => "race-1", "expected_version" => 1, "custom_response" => "First"},
        %{"idempotency_key" => "race-2", "expected_version" => 1, "custom_response" => "Second"}
      ]

      results =
        submissions
        |> Enum.map(&Task.async(fn -> answer(pid, decision.decision_id, &1) end))
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &match?({:ok, %{status: :accepted}}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:conflict, {:already_decided, _}}}, &1)) == 1
    end

    test "a stale request version rejects before append or dispatch", %{dir: dir} do
      parent = self()
      dispatcher = fn _decision, _opts -> send(parent, :unexpected_dispatch) end
      pid = start_store!(dir, dispatcher: dispatcher)
      base = answerable_request("answer-stale")

      assert {:ok, %{decision: v1}} = request(pid, base)
      assert {:ok, %{decision: v2}} = request(pid, Map.merge(base, %{"question" => "Revised?", "version" => 2}))

      stale = %{"idempotency_key" => "stale-1", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:error, {:conflict, {:stale_version, 1, 2}}} = answer(pid, v1.decision_id, stale)
      refute_receive :unexpected_dispatch, 100
      assert v2.answer == nil
      assert {:ok, audit} = DecisionStore.audit_history(v1.decision_id, pid)
      assert Enum.map(audit, &audit_type/1) == [:requested, :requested]
    end

    test "request enrichment after answer keeps dispatch tied to the answered version", %{dir: dir} do
      parent = self()

      dispatcher = fn addressed, _opts ->
        send(parent, {:addressed_request, addressed.version, addressed.question})
        {:ok, %{status: :accepted, item: %{id: 55}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 100)
      base = answerable_request("answer-enrichment")
      assert {:ok, %{decision: v1}} = request(pid, base)

      payload = %{"idempotency_key" => "enrich-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, v1.decision_id, payload)

      assert {:ok, %{decision: v2}} =
               request(pid, Map.merge(base, %{"question" => "Revised after answer?", "version" => 2}))

      assert v2.version == 2
      assert v2.answer == action
      assert_receive {:addressed_request, 1, "Deploy now?"}, 1_000

      settled = wait_for_decision(pid, v1.decision_id, &(&1.delivery_status == :queued))
      assert settled.version == 2
      assert settled.answer.decision_version == 1
    end

    test "restart reconciles a persisted answer that was not yet dispatched", %{dir: dir} do
      parent = self()
      never = fn _decision, _opts -> send(parent, :old_dispatch) end
      pid1 = start_store!(dir, dispatcher: never, dispatch_delay_ms: 5_000, reconcile_delay_ms: 5_000)
      assert {:ok, %{decision: decision}} = request(pid1, answerable_request("answer-restart"))

      payload = %{"idempotency_key" => "restart-1", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, %{status: :accepted, action: action}} = answer(pid1, decision.decision_id, payload)
      GenServer.stop(pid1)
      refute_receive :old_dispatch, 100

      dispatcher = fn replayed, opts ->
        send(parent, {:reconciled, replayed.answer.action_id, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 77}}}
      end

      pid2 = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0, reconcile_delay_ms: 0)
      assert_receive {:reconciled, action_id, _attempt_id}, 1_000
      assert action_id == action.action_id
      _settled = wait_for_decision(pid2, decision.decision_id, &(&1.delivery_status == :queued))
      refute_receive {:reconciled, _, _}, 100
    end

    test "transient dispatch failure is durable and retried with a new attempt", %{dir: dir} do
      parent = self()
      counter = :counters.new(1, [])

      dispatcher = fn _decision, opts ->
        :ok = :counters.add(counter, 1, 1)
        attempt = :counters.get(counter, 1)
        send(parent, {:attempted, attempt, opts[:attempt_id]})

        if attempt == 1,
          do: {:error, :unavailable},
          else: {:ok, %{status: :accepted, item: %{id: 88}}}
      end

      pid =
        start_store!(dir,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0,
          retry_delays_ms: [0]
        )

      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-retry"))
      payload = %{"idempotency_key" => "retry-1", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, _result} = answer(pid, decision.decision_id, payload)

      assert_receive {:attempted, 1, first_attempt}, 1_000
      assert_receive {:attempted, 2, second_attempt}, 1_000
      refute first_attempt == second_attempt

      settled = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      assert Enum.map(settled.dispatch_attempts, & &1.status) == [:failed, :queued]
      assert hd(settled.dispatch_attempts).failure_reason_class == "orchestrator_unavailable"
    end

    test "target-agent failure waits for an explicit idempotent retry", %{dir: dir} do
      parent = self()
      counter = :counters.new(1, [])
      original_log_file = Application.get_env(:aiur, :log_file)
      log_root = Path.join(dir, "target-failure-alert-log")
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

      on_exit(fn ->
        if original_log_file do
          Application.put_env(:aiur, :log_file, original_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end
      end)

      dispatcher = fn _decision, opts ->
        :ok = :counters.add(counter, 1, 1)
        attempt = :counters.get(counter, 1)
        send(parent, {:target_attempt, attempt, opts[:retry_failed]})

        if attempt == 1,
          do: {:error, :no_running_agent},
          else: {:ok, %{status: :accepted, item: %{id: 89}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0, retry_delays_ms: [0])
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-explicit-retry"))
      payload = %{"idempotency_key" => "retry-2", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)

      assert_receive {:target_attempt, 1, false}, 1_000
      failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
      assert List.last(failed.dispatch_attempts).failure_reason_class == "target_agent_unavailable"

      topic = "ticket.979.agent.attention.decision-delivery-#{String.replace(action.action_id, "_", "-")}"
      assert [%{"topic" => ^topic}] = AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true)

      refute_receive {:target_attempt, _, _}, 100

      assert {:ok, :scheduled} = DecisionStore.retry_dispatch(decision.decision_id, action.action_id, pid)
      assert_receive {:target_attempt, 2, true}, 1_000
      settled = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      assert Enum.map(settled.dispatch_attempts, & &1.status) == [:failed, :queued]
      assert AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true) == []
    end

    test "projection repair failure after answer append suppresses dispatch", %{dir: dir} do
      parent = self()
      dispatcher = fn _decision, _opts -> send(parent, :unexpected_dispatch) end
      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-repair"))

      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod!(dir, 0o700) end)

      payload = %{"idempotency_key" => "repair-1", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, %{status: :accepted}} = answer(pid, decision.decision_id, payload)
      assert {:repair, _reason} = DecisionStore.health(pid)
      refute_receive :unexpected_dispatch, 100
    end

    test "correlated handoff and consumption append idempotent transport evidence", %{dir: dir} do
      parent = self()

      dispatcher = fn _decision, opts ->
        send(parent, {:queue_attempt, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 91}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-transport"))
      payload = %{"idempotency_key" => "transport-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      assert_receive {:queue_attempt, attempt_id}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      item = correlated_queue_item(decision, action, attempt_id, 91)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
      assert {:ok, :duplicate} = DecisionStore.record_delivery(item, pid)

      assert :ok = DecisionStore.record_transport_async(:consumed, item, nil, pid)
      consumed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :consumed))
      assert consumed.decision_status == :decided

      assert :ok = DecisionStore.record_transport_async(:consumed, item, nil, pid)
      Process.sleep(20)
      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.count(audit, &(audit_type(&1) == :delivered)) == 1
      assert Enum.count(audit, &(audit_type(&1) == :consumed)) == 1
    end

    test "durable transport failure opens one stable attention and restoration resolves it", %{dir: dir} do
      parent = self()
      original_log_file = Application.get_env(:aiur, :log_file)
      log_root = Path.join(dir, "alert-log")
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

      on_exit(fn ->
        if original_log_file do
          Application.put_env(:aiur, :log_file, original_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end
      end)

      dispatcher = fn _decision, opts ->
        send(parent, {:queue_attempt, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 92}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-attention"))
      payload = %{"idempotency_key" => "attention-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      assert_receive {:queue_attempt, attempt_id}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      item = correlated_queue_item(decision, action, attempt_id, 92)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)

      topic = "ticket.979.agent.attention.decision-delivery-#{String.replace(action.action_id, "_", "-")}"

      assert :ok = DecisionStore.record_transport_async(:failed, item, :send_failed, pid)
      failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
      assert List.last(failed.dispatch_attempts).failure_reason_class == "send_failed"
      assert [%{"topic" => ^topic}] = AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true)

      GenServer.stop(pid)
      pid2 = start_store!(dir, dispatcher: fn _decision, _opts -> {:error, :no_running_agent} end)
      assert [%{"topic" => ^topic}] = AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true)

      assert :ok = DecisionStore.record_transport_async(:restored, item, nil, pid2)
      _restored = wait_for_decision(pid2, decision.decision_id, &(&1.delivery_status == :queued))
      assert AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true) == []
    end

    test "target agent explicitly acknowledges and resolves with duplicate suppression", %{dir: dir} do
      parent = self()

      dispatcher = fn _decision, opts ->
        send(parent, {:lifecycle_attempt, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 93}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-lifecycle"))
      answer_payload = %{"idempotency_key" => "lifecycle-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, answer_payload)
      assert_receive {:lifecycle_attempt, attempt_id}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      item = correlated_queue_item(decision, action, attempt_id, 93)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)

      :ok = Exchange.subscribe("ticket.979.agent.decision.acknowledged")
      :ok = Exchange.subscribe("ticket.979.agent.decision.resolved")

      lifecycle_payload = %{
        "decision_id" => decision.decision_id,
        "action_id" => action.action_id,
        "expected_version" => 1,
        "detail" => "Observed and applying the answer"
      }

      lifecycle_opts = [
        ticket_identifier: "979",
        actor: %{kind: :agent, id: "ticket-agent"},
        source: %{agent_id: "codex", session_id: "session-1", invocation_id: "call-1"}
      ]

      assert {:ok, %{status: :accepted, decision_status: :acknowledged}} =
               DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, lifecycle_opts, pid)

      assert_receive {:event, %{topic: "ticket.979.agent.decision.acknowledged"}}, 500

      assert {:ok, %{status: :duplicate}} =
               DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, lifecycle_opts, pid)

      refute_receive {:event, %{topic: "ticket.979.agent.decision.acknowledged"}}, 100

      reconnected_opts =
        Keyword.put(lifecycle_opts, :source, %{
          agent_id: "codex",
          session_id: "session-2",
          invocation_id: "call-2"
        })

      assert {:ok, %{status: :duplicate}} =
               DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, reconnected_opts, pid)

      conflicting = Map.put(lifecycle_payload, "detail", "Different acknowledgement")

      assert {:error, {:conflict, {:already_acknowledged, action_id}}} =
               DecisionStore.agent_lifecycle(:acknowledged, conflicting, lifecycle_opts, pid)

      assert action_id == action.action_id

      resolved_payload = Map.put(lifecycle_payload, "detail", "Applied successfully")

      assert {:ok, %{status: :accepted, decision_status: :resolved}} =
               DecisionStore.agent_lifecycle(:resolved, resolved_payload, lifecycle_opts, pid)

      assert_receive {:event, %{topic: "ticket.979.agent.decision.resolved"}}, 500
      assert {:ok, current} = DecisionStore.get(decision.decision_id, pid)
      assert current.acknowledgement.detail == "Observed and applying the answer"
      assert current.acknowledgement.source.session_id == "session-1"
      assert current.resolution.detail == "Applied successfully"
    end

    test "agent lifecycle rejects wrong correlation and illegal ordering without append", %{dir: dir} do
      parent = self()

      dispatcher = fn _decision, opts ->
        send(parent, {:invalid_lifecycle_attempt, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 94}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-lifecycle-invalid"))
      answer_payload = %{"idempotency_key" => "lifecycle-2", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, answer_payload)
      assert_receive {:invalid_lifecycle_attempt, attempt_id}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      payload = %{"decision_id" => decision.decision_id, "action_id" => action.action_id, "expected_version" => 1}
      opts = [ticket_identifier: "979", actor: %{kind: :agent, id: "agent-session-2"}]

      assert {:error, {:invalid_transition, :not_delivered}} =
               DecisionStore.agent_lifecycle(:acknowledged, payload, opts, pid)

      assert {:error, {:invalid_transition, :not_acknowledged}} =
               DecisionStore.agent_lifecycle(:resolved, payload, opts, pid)

      assert {:error, {:conflict, {:ticket_mismatch, "980", "979"}}} =
               DecisionStore.agent_lifecycle(:acknowledged, payload, Keyword.put(opts, :ticket_identifier, "980"), pid)

      wrong_action = Map.put(payload, "action_id", "act_wrong")

      assert {:error, {:conflict, {:action_mismatch, "act_wrong", _current}}} =
               DecisionStore.agent_lifecycle(:acknowledged, wrong_action, opts, pid)

      stale = Map.put(payload, "expected_version", 2)

      assert {:error, {:conflict, {:stale_version, 2, 1}}} =
               DecisionStore.agent_lifecycle(:acknowledged, stale, opts, pid)

      item = correlated_queue_item(decision, action, attempt_id, 94)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
      assert {:ok, %{status: :accepted}} = DecisionStore.agent_lifecycle(:acknowledged, payload, opts, pid)

      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.count(audit, &(audit_type(&1) == :acknowledged)) == 1
      assert Enum.count(audit, &(audit_type(&1) == :resolved)) == 0
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

      :ok = DecisionLog.append(Path.join(dir, "decisions.ndjson"), DecisionEvent.to_json_safe(invalid))
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

  defp answerable_request(source_id) do
    %{
      "question" => "Deploy now?",
      "blocking" => true,
      "source_id" => source_id,
      "options" => [%{"id" => "ship", "label" => "Ship it"}]
    }
  end

  defp audit_type(%DecisionEvent{type: type}), do: type
  defp audit_type(%Aiur.Decision{}), do: :requested

  defp correlated_queue_item(decision, action, attempt_id, queue_item_id) do
    %{
      id: queue_item_id,
      target_issue_identifier: decision.ticket.identifier,
      action_id: action.action_id,
      correlation: %{
        decision_id: decision.decision_id,
        decision_version: action.decision_version,
        action_id: action.action_id,
        attempt_id: attempt_id,
        actor: action.actor
      }
    }
  end

  defp wait_for_decision(pid, decision_id, predicate, attempts \\ 100)

  defp wait_for_decision(_pid, _decision_id, _predicate, 0), do: flunk("decision did not reach expected state")

  defp wait_for_decision(pid, decision_id, predicate, attempts) do
    {:ok, decision} = DecisionStore.get(decision_id, pid)

    if predicate.(decision) do
      decision
    else
      Process.sleep(10)
      wait_for_decision(pid, decision_id, predicate, attempts - 1)
    end
  end
end
