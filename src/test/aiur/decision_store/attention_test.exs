Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.AttentionTest do
  use Aiur.DecisionStoreCase, async: false

  describe "legacy attention projection and enrichment" do
    test "internal delivery alerts never appear as operator Commands", %{dir: dir} do
      pid = start_store!(dir)
      slug = "decision-delivery-act-1"

      payload = %{
        "question" => "Decision action remains actionable after turn_failed.",
        "blocking" => true,
        "kind" => "legacy_attention",
        "source_id" => "legacy_attention:#{slug}"
      }

      assert {:ok, %{status: :accepted, decision: decision}} =
               DecisionStore.project_attention(
                 payload,
                 [
                   ticket: @ticket,
                   source: @source,
                   legacy_attention: %{
                     slug: slug,
                     topic: "ticket.979.agent.attention.#{slug}"
                   }
                 ],
                 pid
               )

      assert {:ok, %{decisions: [], total: 0, counts: %{open: 0, blocking: 0}}} =
               DecisionStore.retained_query(
                 %{limit: 25, cursor: nil, lifecycle: nil, search: nil, ticket: nil},
                 pid
               )

      assert {:ok, ^decision} = DecisionStore.get(decision.decision_id, pid)
    end

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

    test "changed legacy evidence re-arms an operator-dismissed attention", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{decision: v1}} = project_attention(pid, minimal_attention("Original blocker evidence"))
      assert {:ok, %{decision: dismissed}} = DecisionStore.dismiss(v1.decision_id, [actor: %{kind: :operator, id: "dashboard"}], pid)
      assert dismissed.decision_status == :dismissed

      assert {:ok, %{decision: rearmed}} = project_attention(pid, minimal_attention("New blocker evidence"))
      assert rearmed.version == 2
      assert rearmed.decision_status == :open
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
end
