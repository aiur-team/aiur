defmodule Aiur.DecisionStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.AgentRunner.EventsDigest
  alias Aiur.{AlertFeed, Boot, DecisionEvent, DecisionHistory, DecisionLog, DecisionPubSub, DecisionStore}
  alias Aiur.DecisionStore.RetainedSnapshot
  alias Aiur.Events.{Exchange, IdGenerator}
  alias AiurWeb.ControlCenterPresenter

  @ticket %{identifier: "979", title: "OCC-1", url: "https://github.com/aiur-team/aiur/issues/979"}
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

  test "dashboard projections stay bounded with 10k stored decisions", %{dir: dir} do
    pid = start_store!(dir)

    assert {:ok, %{decision: decision}} = request(pid, %{"question" => "Bound this history?", "blocking" => false})
    %{audit_history: audit_history} = :sys.get_state(pid)
    [event] = Map.fetch!(audit_history, decision.decision_id)

    records =
      Enum.map(1..10_000, fn index ->
        decision_id = "dec-#{index}"
        created_at = DateTime.add(event.data.created_at, index, :microsecond)

        %{
          event
          | decision_id: decision_id,
            data: %{event.data | decision_id: decision_id, created_at: created_at, source_created_at: created_at}
        }
      end)

    current = Map.new(records, &{&1.decision_id, &1.data})

    decision_index =
      records
      |> Enum.map(&decision_index_key(&1.data))
      |> :gb_sets.from_list()

    retained_index = RetainedSnapshot.build_index(current)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | audit_history: Map.new(records, &{&1.decision_id, [&1]}),
          current: current,
          decision_index: decision_index,
          retained_index: retained_index,
          recent_audit: records |> Enum.reverse() |> Enum.take(50)
      }
    end)

    recent = DecisionStore.recent_audit_history(10_000, pid)

    assert length(recent.records) == 50
    assert Enum.map(recent.records, & &1.decision_id) == Enum.map(10_000..9_951//-1, &"dec-#{&1}")
    assert map_size(recent.contexts) == 50
    assert map_size(:sys.get_state(pid).audit_history) == 10_000

    payload =
      ControlCenterPresenter.state_payload(:unused, 10,
        decision_store: pid,
        fleet_fun: fn -> %{generated_at: nil, counts: %{}, analytics: nil} end,
        history_fun: fn -> [] end,
        recent_merges_fun: fn -> %{merges: [], health: :ready, reconciliation: %{}} end
      )

    assert length(payload.decisions) == 50

    assert MapSet.new(payload.decisions, & &1.decision_id) ==
             MapSet.new(10_000..9_951//-1, &"dec-#{&1}")

    assert {:ok, %{decisions: page, has_next?: true, total: 10_000, counts: %{open: 10_000, blocking: 0}}} =
             DecisionStore.retained_query(
               %{limit: 2, cursor: nil, lifecycle: nil, search: nil, ticket: nil},
               pid
             )

    assert length(page) == 2
  end

  test "resolving a cached decision backfills the untouched 51st open decision", %{dir: dir} do
    parent = self()

    dispatcher = fn _decision, opts ->
      send(parent, {:backfill_dispatch, opts[:attempt_id]})
      {:ok, %{status: :accepted, item: %{id: 51}}}
    end

    pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)

    assert {:ok, %{decision: cached}} =
             request(pid, %{
               "source_id" => "cached-blocker",
               "question" => "Resolve this cached blocker?",
               "blocking" => true,
               "options" => [%{"id" => "ship", "label" => "Ship"}]
             })

    assert {:ok, %{action: action}} =
             answer(pid, cached.decision_id, %{
               "idempotency_key" => "cached-blocker-answer",
               "expected_version" => 1,
               "option_id" => "ship"
             })

    assert_receive {:backfill_dispatch, attempt_id}, 1_000
    _queued = wait_for_decision(pid, cached.decision_id, &(&1.delivery_status == :queued))
    assert {:ok, :accepted} = DecisionStore.record_delivery(correlated_queue_item(cached, action, attempt_id, 51), pid)

    untouched =
      for index <- 1..50 do
        assert {:ok, %{decision: decision}} =
                 request(pid, %{
                   "source_id" => "untouched-#{index}",
                   "question" => "Untouched open decision #{index}?",
                   "blocking" => false
                 })

        decision
      end

    assert length(DecisionStore.recent_decisions(50, pid)) == 50
    assert Enum.any?(DecisionStore.recent_decisions(50, pid), &(&1.decision_id == cached.decision_id))

    lifecycle_payload = %{
      "decision_id" => cached.decision_id,
      "action_id" => action.action_id,
      "expected_version" => 1
    }

    lifecycle_opts = [
      ticket_identifier: "979",
      actor: %{kind: :agent, id: "ticket-agent"},
      source: %{agent_id: "codex", session_id: "session-1", invocation_id: "backfill-test"}
    ]

    assert {:ok, %{status: :accepted}} =
             DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, lifecycle_opts, pid)

    assert {:ok, %{status: :accepted, decision_status: :resolved}} =
             DecisionStore.agent_lifecycle(:resolved, lifecycle_payload, lifecycle_opts, pid)

    projected_ids = MapSet.new(DecisionStore.recent_decisions(50, pid), & &1.decision_id)
    refute MapSet.member?(projected_ids, cached.decision_id)
    assert projected_ids == MapSet.new(untouched, & &1.decision_id)
  end

  defp request(pid, payload, opts \\ []) do
    DecisionStore.request(payload, Keyword.merge([ticket: @ticket, source: @source], opts), pid)
  end

  test "dismiss is durable, idempotent, historic, and write-gated", %{dir: dir} do
    pid = start_store!(dir)

    assert {:ok, %{decision: decision}} =
             request(pid, %{
               "question" => "Use blue or green?",
               "blocking" => true,
               "options" => [
                 %{"id" => "blue", "label" => "Blue"},
                 %{"id" => "green", "label" => "Green"}
               ]
             })

    opts = [actor: %{kind: :operator, id: "dashboard"}]

    assert {:ok, %{status: :accepted, decision: dismissed}} =
             DecisionStore.dismiss(decision.decision_id, opts, pid)

    assert dismissed.decision_status == :dismissed
    assert dismissed.answer == nil

    assert {:ok, %{status: :duplicate, decision: replayed}} =
             DecisionStore.dismiss(decision.decision_id, opts, pid)

    assert replayed.decision_status == :dismissed

    assert {:ok, %{decisions: [historic], total: 1}} =
             DecisionStore.retained_query(
               %{limit: 25, cursor: nil, lifecycle: :historic, search: nil, ticket: nil},
               pid
             )

    assert historic.decision_id == decision.decision_id

    :sys.replace_state(pid, &%{&1 | writable?: false, health: {:corrupt, 1, :test}})

    assert {:error, {:store_unavailable, {:corrupt, 1, :test}}} =
             DecisionStore.dismiss(decision.decision_id, opts, pid)

    GenServer.stop(pid)
    restarted = start_store!(dir)
    assert {:ok, durable} = DecisionStore.get(decision.decision_id, restarted)
    assert durable.decision_status == :dismissed
  end

  test "deferral is durable, idempotent, and remains answerable", %{dir: dir} do
    pid = start_store!(dir)

    assert {:ok, %{decision: decision}} = request(pid, %{"question" => "Use the release train?", "blocking" => true})
    opts = [actor: %{kind: :operator, id: "dashboard"}]

    assert {:ok, %{status: :accepted, decision: deferred}} = DecisionStore.defer(decision.decision_id, opts, pid)
    assert deferred.decision_status == :deferred
    assert deferred.answer == nil

    assert {:ok, %{status: :duplicate, decision: replayed}} = DecisionStore.defer(decision.decision_id, opts, pid)
    assert replayed.decision_status == :deferred

    GenServer.stop(pid)
    restarted = start_store!(dir)
    assert {:ok, durable} = DecisionStore.get(decision.decision_id, restarted)
    assert durable.decision_status == :deferred

    assert {:ok, %{decision: answerable}} =
             answer(restarted, decision.decision_id, %{
               "idempotency_key" => "deferred-answer",
               "expected_version" => 1,
               "custom_response" => "Use the release train"
             })

    assert answerable.decision_status == :decided
  end

  test "expiration is durable, idempotent, historic, and auditable", %{dir: dir} do
    pid = start_store!(dir)
    created_at = ~U[2026-07-24 12:00:00Z]
    expired_at = DateTime.add(created_at, 600, :second)

    assert {:ok, %{decision: decision}} =
             request(pid, %{"question" => "Still waiting?", "blocking" => true}, now: created_at)

    assert {:ok, %{status: :accepted, decision: expired}} =
             DecisionStore.expire(decision.decision_id, "agent_not_running", [now: expired_at], pid)

    assert expired.decision_status == :expired
    assert expired.answer == nil

    assert {:ok, %{status: :duplicate, decision: duplicate}} =
             DecisionStore.expire(decision.decision_id, "agent_not_running", [], pid)

    assert duplicate.decision_status == :expired

    answer_payload = %{"idempotency_key" => "too-late", "expected_version" => 1, "custom_response" => "Ship"}
    assert {:error, {:conflict, :expired}} = answer(pid, decision.decision_id, answer_payload)

    assert {:ok, %{decisions: [historic], total: 1}} =
             DecisionStore.retained_query(
               %{limit: 25, cursor: nil, lifecycle: :historic, search: nil, ticket: nil},
               pid
             )

    assert historic.decision_id == decision.decision_id

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)

    assert [
             %DecisionEvent{type: :requested},
             %DecisionEvent{type: :decision_expired, data: %{reason_class: "agent_not_running"}}
           ] = audit

    GenServer.stop(pid)
    restarted = start_store!(dir)
    assert {:ok, replayed} = DecisionStore.get(decision.decision_id, restarted)
    assert replayed.decision_status == :expired
  end

  defp decision_index_key(decision) do
    urgency = %{low: 0, normal: 1, high: 2, critical: 3}

    {
      decision.decision_status in [:expired, :dismissed, :resolved],
      not decision.blocking,
      -Map.fetch!(urgency, decision.urgency),
      -DateTime.to_unix(decision.created_at, :microsecond),
      decision.decision_id
    }
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

  defp dispatch_fence_size({:dispatch_action, fence, false}),
    do: fence |> :erlang.term_to_binary() |> byte_size()

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
        url: "https://github.com/aiur-team/aiur/issues/979?token=#{secret}"
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

      assert_receive {:event,
                      %{
                        "event_id" => "decision-provenance-v1:" <> reserved_event_id,
                        topic: "ticket.979.agent.decision.enriched",
                        id: cursor_event_id
                      }},
                     500

      assert cursor_event_id > 0
      assert reserved_event_id == Integer.to_string(cursor_event_id)
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

    test "a non-durable enrichment ID reservation appends nothing", %{dir: dir} do
      pid = start_store!(dir, event_id_reserver: fn -> {:error, :not_durable} end)
      assert {:ok, %{decision: v1}} = request(pid, minimal_attention())

      patch = %{"context" => %{"short_summary" => "Must remain durable"}}
      assert {:error, :event_id_not_durable} = enrich(pid, v1.decision_id, patch, 1)

      assert {:ok, ^v1} = DecisionStore.get(v1.decision_id, pid)
      assert {:ok, [requested]} = DecisionStore.audit_history(v1.decision_id, pid)
      assert audit_type(requested) == :requested
      assert length(String.split(File.read!(Path.join(dir, "decisions.ndjson")), "\n", trim: true)) == 1
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
      dispatches = :counters.new(1, [])
      release_scheduled_work = :atomics.new(1, [])

      dispatcher = fn _decision, _opts ->
        :counters.add(dispatches, 1, 1)
        send(parent, {:dispatched, :counters.get(dispatches, 1)})
        {:ok, %{status: :accepted, item: %{id: 101}}}
      end

      dispatch_scheduler = fn recipient, message, delay_ms ->
        send(parent, {:dispatch_scheduled, recipient, message, delay_ms})

        if :atomics.get(release_scheduled_work, 1) == 1,
          do: send(recipient, message)

        make_ref()
      end

      store_opts = [
        dispatcher: dispatcher,
        dispatch_delay_ms: 0,
        reconcile_delay_ms: 0,
        dispatch_scheduler: dispatch_scheduler
      ]

      pid = start_store!(dir, store_opts)

      assert_receive {:dispatch_scheduled, ^pid, {:reconcile_dispatches, []}, 0}, 2_000

      assert {:ok, %{decision: v1}} = request(pid, answerable_request("enrich-after-answer"))

      answer_payload = %{
        "idempotency_key" => "answer-before-enrichment",
        "expected_version" => 1,
        "option_id" => "ship"
      }

      assert {:ok, %{action: accepted}} = answer(pid, v1.decision_id, answer_payload)
      assert_receive {:dispatch_scheduled, ^pid, scheduled_dispatch, 0}, 2_000
      assert match?({:dispatch_action, _fence, false}, scheduled_dispatch)
      send(pid, scheduled_dispatch)
      assert_receive {:dispatched, 1}, 2_000
      settled = wait_for_decision(pid, v1.decision_id, &(&1.delivery_status == :queued))

      GenServer.stop(pid)
      replayed_pid = start_store!(dir, store_opts)

      assert_receive {:dispatch_scheduled, ^replayed_pid, {:reconcile_dispatches, [%{request_version: 1}]} = scheduled_reconciliation, 0},
                     2_000

      patch = %{"context" => %{"short_summary" => "Additional context"}}

      assert {:ok, %{status: :accepted, decision: enriched}} =
               enrich(
                 replayed_pid,
                 v1.decision_id,
                 patch,
                 1
               )

      assert enriched.version == 2
      assert enriched.answer == accepted
      assert enriched.delivery_status == :queued
      assert enriched.dispatch_attempts == settled.dispatch_attempts

      assert {:ok, %{status: :duplicate, decision: replayed}} =
               enrich(replayed_pid, v1.decision_id, patch, 1)

      assert replayed.answer == accepted
      assert replayed.delivery_status == :queued
      assert replayed.dispatch_attempts == settled.dispatch_attempts

      :atomics.put(release_scheduled_work, 1, 1)
      send(replayed_pid, scheduled_reconciliation)

      refute_receive {:dispatch_scheduled, ^replayed_pid, _message, _delay_ms}, 100
      refute_receive {:dispatched, 2}, 100
      assert :counters.get(dispatches, 1) == 1
    end

    test "pending first delivery survives enrichment before restart reconciliation", %{dir: dir} do
      parent = self()
      dispatches = :counters.new(1, [])
      release_scheduled_work = :atomics.new(1, [])

      dispatcher = fn decision, _opts ->
        :counters.add(dispatches, 1, 1)
        send(parent, {:pending_dispatched, :counters.get(dispatches, 1), decision.version})
        {:ok, %{status: :accepted, item: %{id: 102}}}
      end

      dispatch_scheduler = fn recipient, message, delay_ms ->
        send(parent, {:dispatch_scheduled, recipient, message, delay_ms})

        if :atomics.get(release_scheduled_work, 1) == 1,
          do: send(recipient, message)

        make_ref()
      end

      store_opts = [
        dispatcher: dispatcher,
        dispatch_delay_ms: 0,
        reconcile_delay_ms: 0,
        dispatch_scheduler: dispatch_scheduler
      ]

      pid = start_store!(dir, store_opts)
      assert_receive {:dispatch_scheduled, ^pid, {:reconcile_dispatches, []}, 0}, 2_000
      assert {:ok, %{decision: v1}} = request(pid, answerable_request("enrich-pending-answer"))

      answer_payload = %{
        "idempotency_key" => "pending-answer-before-enrichment",
        "expected_version" => 1,
        "option_id" => "ship"
      }

      assert {:ok, %{action: accepted}} = answer(pid, v1.decision_id, answer_payload)
      assert_receive {:dispatch_scheduled, ^pid, {:dispatch_action, _fence, false}, 0}, 2_000
      GenServer.stop(pid)

      replayed_pid = start_store!(dir, store_opts)

      assert_receive {:dispatch_scheduled, ^replayed_pid, {:reconcile_dispatches, [%{request_version: 1}]} = scheduled_reconciliation, 0},
                     2_000

      patch = %{"context" => %{"short_summary" => "Context before first delivery"}}

      assert {:ok, %{status: :accepted, decision: enriched}} =
               enrich(replayed_pid, v1.decision_id, patch, 1)

      assert enriched.version == 2
      assert enriched.answer == accepted
      assert enriched.delivery_status == :pending
      assert enriched.dispatch_attempts == []

      :atomics.put(release_scheduled_work, 1, 1)
      send(replayed_pid, scheduled_reconciliation)

      assert_receive {:pending_dispatched, 1, 1}, 2_000
      settled = wait_for_decision(replayed_pid, v1.decision_id, &(&1.delivery_status == :queued))
      assert settled.version == 2
      assert settled.answer == accepted
      assert Enum.map(settled.dispatch_attempts, & &1.status) == [:queued]
      refute_receive {:pending_dispatched, 2, _version}, 100
      assert :counters.get(dispatches, 1) == 1
    end

    test "dispatch lifecycle fences stay bounded across repeated retries", %{dir: dir} do
      parent = self()
      attempts = :counters.new(1, [])

      dispatcher = fn _decision, _opts ->
        :counters.add(attempts, 1, 1)
        send(parent, {:dispatch_attempted, :counters.get(attempts, 1)})
        {:error, :unavailable}
      end

      scheduler = fn recipient, message, delay_ms ->
        send(parent, {:dispatch_scheduled, recipient, message, delay_ms})
        make_ref()
      end

      pid =
        start_store!(dir,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0,
          reconcile_delay_ms: 0,
          retry_delays_ms: List.duplicate(0, 25),
          dispatch_scheduler: scheduler
        )

      assert_receive {:dispatch_scheduled, ^pid, {:reconcile_dispatches, []}, 0}, 2_000
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("bounded-dispatch-fence"))

      payload = %{"idempotency_key" => "bounded-fence", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, _result} = answer(pid, decision.decision_id, payload)
      assert_receive {:dispatch_scheduled, ^pid, initial_dispatch, 0}, 2_000
      send(pid, initial_dispatch)
      assert_receive {:dispatch_attempted, 1}, 2_000
      assert_receive {:dispatch_scheduled, ^pid, first_retry, 0}, 2_000

      baseline_size = dispatch_fence_size(first_retry)

      sizes =
        Enum.reduce(2..20, {first_retry, [baseline_size]}, fn attempt, {scheduled, sizes} ->
          send(pid, scheduled)
          assert_receive {:dispatch_attempted, ^attempt}, 2_000
          assert_receive {:dispatch_scheduled, ^pid, next_retry, 0}, 2_000
          {next_retry, [dispatch_fence_size(next_retry) | sizes]}
        end)
        |> elem(1)

      assert Enum.max(sizes) <= baseline_size + 64
      assert :counters.get(attempts, 1) == 20
    end
  end

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

    test "trusted provenance remains attached to its accepted version after replay", %{dir: dir} do
      pid1 = start_store!(dir)

      provenance = %{
        agent_family: "codex",
        backend: "codex",
        requested_model: "gpt-5.6-terra",
        session_id: "thread-123",
        attempt_id: "attempt-456",
        source: "agent_runner"
      }

      assert {:ok, %{decision: accepted}} =
               request(pid1, %{"question" => "Keep runtime facts?", "blocking" => true}, provenance: provenance)

      GenServer.stop(pid1)
      pid2 = start_store!(dir)

      assert {:ok, replayed} = DecisionStore.get(accepted.decision_id, pid2)
      assert replayed.provenance == accepted.provenance
      assert {:ok, [^replayed]} = DecisionStore.history(accepted.decision_id, pid2)

      assert [history] = DecisionHistory.list(server: pid2, limit: 1)
      assert history.provenance["backend"] == "codex"
      assert history.provenance["session_id"] == "thread-123"
    end

    test "replays trusted provenance and supervisor basis through the full revised lifecycle", %{dir: dir} do
      parent = self()

      dispatcher = fn _decision, opts ->
        send(parent, {:provenance_lifecycle_attempt, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 711}}}
      end

      for confidence <- [0, 50, 100] do
        store_dir = Path.join(dir, "provenance-lifecycle-#{confidence}")
        pid = start_store!(store_dir, dispatcher: dispatcher, dispatch_delay_ms: 0)

        provenance = %{
          agent_family: "codex",
          backend: "codex",
          requested_model: "gpt-5.6-terra",
          resolved_model: "gpt-5.6-terra",
          session_id: "thread-#{confidence}",
          attempt_id: "attempt-#{confidence}",
          source: "agent_runner"
        }

        assert {:ok, %{decision: accepted}} =
                 request(
                   pid,
                   %{
                     "question" => "Apply the approved architecture change?",
                     "blocking" => true,
                     "source_id" => "provenance-lifecycle-#{confidence}",
                     "kind" => "architecture",
                     "authority" => "supervisor_allowed",
                     "reversibility" => "reversible",
                     "options" => [%{"id" => "ship", "label" => "Ship it"}]
                   },
                   provenance: provenance
                 )

        supervisor_opts = [actor: %{kind: :supervisor, id: "supervising-agent"}, supervisor_basis: supervisor_basis(confidence)]

        assert {:ok, %{action: answer}} =
                 answer(
                   pid,
                   accepted.decision_id,
                   %{"idempotency_key" => "provenance-answer-#{confidence}", "expected_version" => 1, "option_id" => "ship"},
                   supervisor_opts
                 )

        assert_receive {:provenance_lifecycle_attempt, _initial_attempt_id}, 1_000
        _queued = wait_for_decision(pid, accepted.decision_id, &(&1.delivery_status == :queued))

        assert {:ok, %{action: revision}} =
                 DecisionStore.revise(
                   accepted.decision_id,
                   %{
                     "idempotency_key" => "provenance-revision-#{confidence}",
                     "expected_version" => 1,
                     "expected_action_id" => answer.action_id,
                     "expected_revision_sequence" => 0,
                     "option_id" => "ship",
                     "rationale" => "Confirmed after the delivery check."
                   },
                   supervisor_opts,
                   pid
                 )

        assert_receive {:provenance_lifecycle_attempt, revision_attempt_id}, 1_000

        _queued =
          wait_for_decision(pid, accepted.decision_id, fn decision ->
            decision.delivery_status == :queued and decision.active_action_id == revision.action_id
          end)

        assert {:ok, :accepted} =
                 DecisionStore.record_delivery(correlated_queue_item(accepted, revision, revision_attempt_id, 711), pid)

        lifecycle_payload = %{
          "decision_id" => accepted.decision_id,
          "action_id" => revision.action_id,
          "expected_version" => 1
        }

        lifecycle_opts = [
          ticket_identifier: "979",
          actor: %{kind: :agent, id: "ticket-agent"},
          source: %{agent_id: "codex", session_id: "session-#{confidence}", invocation_id: "lifecycle-#{confidence}"}
        ]

        assert {:ok, %{status: :accepted, decision_status: :acknowledged}} =
                 DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, lifecycle_opts, pid)

        assert {:ok, %{status: :accepted, decision_status: :resolved}} =
                 DecisionStore.agent_lifecycle(:resolved, lifecycle_payload, lifecycle_opts, pid)

        GenServer.stop(pid)
        replayed_pid = start_store!(store_dir, dispatch_delay_ms: 60_000)

        assert {:ok, replayed} = DecisionStore.get(accepted.decision_id, replayed_pid)
        assert replayed.provenance == accepted.provenance
        assert replayed.answer.supervisor_basis.confidence == confidence
        assert List.last(replayed.revisions).answer.supervisor_basis.confidence == confidence
        assert replayed.delivery_status == :delivered
        assert replayed.decision_status == :resolved
        assert replayed.acknowledgement.action_id == revision.action_id
        assert replayed.resolution.action_id == revision.action_id

        history = DecisionHistory.list(server: replayed_pid)

        assert Enum.all?(history, &(&1.provenance["backend"] == "codex"))

        assert Enum.any?(history, fn entry ->
                 entry.change == :answered and entry.supervisor_basis["confidence"] == confidence
               end)

        assert Enum.any?(history, fn entry ->
                 entry.change == :revised and entry.supervisor_basis["confidence"] == confidence
               end)

        assert Enum.any?(history, fn entry ->
                 entry.dispatch_result == :delivered and entry.supervisor_basis["confidence"] == confidence
               end)

        assert Enum.any?(history, fn entry ->
                 entry.acknowledgement_result == :acknowledged and entry.supervisor_basis["confidence"] == confidence
               end)

        assert Enum.any?(history, fn entry ->
                 entry.acknowledgement_result == :resolved and entry.supervisor_basis["confidence"] == confidence
               end)

        limited_history = DecisionHistory.list(server: replayed_pid, limit: 50)

        assert Enum.any?(limited_history, fn entry ->
                 entry.action_id == answer.action_id and entry.dispatch_result == :dispatch_queued and
                   entry.supervisor_basis["confidence"] == confidence
               end)

        assert Enum.any?(limited_history, fn entry ->
                 entry.action_id == revision.action_id and entry.dispatch_result == :delivered and
                   entry.supervisor_basis["confidence"] == confidence
               end)

        GenServer.stop(replayed_pid)
      end
    end

    test "a decision with an artifact survives restart without being flagged as corrupt", %{dir: dir} do
      pid1 = start_store!(dir)

      payload = %{
        "question" => "Deploy now?",
        "blocking" => true,
        "source_id" => "retry-1",
        "artifacts" => ["https://github.com/aiur-team/aiur"]
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

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0, reconcile_delay_ms: 5_000)
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

    test "transient dispatch failure is retried after request enrichment", %{dir: dir} do
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

      dispatch_scheduler = fn recipient, message, delay_ms ->
        send(parent, {:retry_scheduled, recipient, message, delay_ms})
        make_ref()
      end

      pid =
        start_store!(dir,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0,
          reconcile_delay_ms: 0,
          retry_delays_ms: [0],
          dispatch_scheduler: dispatch_scheduler
        )

      assert_receive {:retry_scheduled, ^pid, {:reconcile_dispatches, []}, 0}, 2_000
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-retry-enrichment"))
      payload = %{"idempotency_key" => "retry-1", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, _result} = answer(pid, decision.decision_id, payload)

      assert_receive {:retry_scheduled, ^pid, first_dispatch, 0}, 2_000
      send(pid, first_dispatch)
      assert_receive {:attempted, 1, first_attempt}, 1_000
      assert_receive {:retry_scheduled, ^pid, scheduled_retry, 0}, 2_000

      patch = %{"context" => %{"short_summary" => "Context before retry"}}

      assert {:ok, %{status: :accepted, decision: enriched}} =
               enrich(pid, decision.decision_id, patch, 1)

      assert enriched.version == 2
      assert enriched.delivery_status == :failed
      assert Enum.map(enriched.dispatch_attempts, & &1.status) == [:failed]

      send(pid, scheduled_retry)
      assert_receive {:attempted, 2, second_attempt}, 1_000
      refute first_attempt == second_attempt

      settled = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      assert settled.version == 2
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

    test "background lifecycle append failure stays scoped and can be retried", %{dir: dir} do
      parent = self()
      reservation_count = :counters.new(1, [])
      original_log_file = Application.get_env(:aiur, :log_file)
      log_root = Path.join(dir, "append-failure-alert-log")
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

      on_exit(fn ->
        if original_log_file do
          Application.put_env(:aiur, :log_file, original_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end
      end)

      event_id_reserver = fn ->
        :ok = :counters.add(reservation_count, 1, 1)
        reservation = :counters.get(reservation_count, 1)
        send(parent, {:lifecycle_reservation, reservation})

        if reservation == 2,
          do: {:error, :not_durable},
          else: IdGenerator.reserve_durable_id()
      end

      dispatcher = fn _decision, _opts ->
        send(parent, :background_dispatch)
        {:ok, %{status: :accepted, item: %{id: 96}}}
      end

      pid =
        start_store!(dir,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0,
          retry_delays_ms: [],
          event_id_reserver: event_id_reserver
        )

      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-append-failure"))
      payload = %{"idempotency_key" => "append-failure-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      assert_receive {:lifecycle_reservation, 1}, 1_000
      assert_receive :background_dispatch, 1_000
      assert_receive {:lifecycle_reservation, 2}, 1_000

      assert DecisionStore.health(pid) == :writable
      assert {:ok, %{status: :accepted}} = request(pid, %{"question" => "Independent?", "blocking" => false})

      topic =
        "ticket.979.agent.attention.decision-lifecycle-persistence-#{String.replace(action.action_id, "_", "-")}"

      assert [%{"topic" => ^topic}] = AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true)

      assert {:ok, :scheduled} = DecisionStore.retry_dispatch(decision.decision_id, action.action_id, pid)
      assert_receive :background_dispatch, 1_000
      assert_receive {:lifecycle_reservation, 3}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      assert AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true) == []
    end

    test "boot reconciliation tolerates failed delivery without an attempt", %{dir: dir} do
      pid = start_store!(dir, dispatch_delay_ms: 5_000, reconcile_delay_ms: 5_000)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-empty-failure"))
      payload = %{"idempotency_key" => "empty-failure-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, _result} = answer(pid, decision.decision_id, payload)
      assert {:ok, current} = DecisionStore.get(decision.decision_id, pid)

      malformed = %{current | delivery_status: :failed, dispatch_attempts: []}
      state = :sys.get_state(pid)
      state = %{state | current: Map.put(state.current, decision.decision_id, malformed)}

      assert {:noreply, _state} = DecisionStore.handle_continue(:schedule_reconciliation, state)
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

    test "delivery adopts queue acceptance when handoff wins the settlement race", %{dir: dir} do
      parent = self()

      dispatcher = fn dispatched, opts ->
        item = correlated_queue_item(dispatched, dispatched.answer, opts[:attempt_id], 97)
        send(parent, {:handoff_before_settlement, self(), item})

        receive do
          :release_settlement -> {:ok, %{status: :accepted, item: item}}
        end
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-handoff-race"))
      payload = %{"idempotency_key" => "handoff-race-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, _result} = answer(pid, decision.decision_id, payload)
      assert_receive {:handoff_before_settlement, dispatcher_pid, item}, 1_000

      assert {:ok, :accepted} = DecisionStore.validate_delivery(item, pid)
      assert {:ok, before_delivery} = DecisionStore.get(decision.decision_id, pid)
      assert before_delivery.dispatch_attempts == []

      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
      delivered = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :delivered))
      assert [%{attempt_id: attempt_id, status: :delivered}] = delivered.dispatch_attempts
      assert attempt_id == item.correlation.attempt_id

      send(dispatcher_pid, :release_settlement)
      Process.sleep(50)
      assert {:ok, settled} = DecisionStore.get(decision.decision_id, pid)
      assert [%{status: :delivered}] = settled.dispatch_attempts
    end

    test "delivery adopts restoration when a failed retry wins the settlement race", %{dir: dir} do
      parent = self()
      dispatches = :counters.new(1, [])

      dispatcher = fn dispatched, opts ->
        :ok = :counters.add(dispatches, 1, 1)

        case :counters.get(dispatches, 1) do
          1 ->
            item = correlated_queue_item(dispatched, dispatched.answer, opts[:attempt_id], 98)
            send(parent, {:initial_retry_item, item})
            {:ok, %{status: :accepted, item: item}}

          2 ->
            send(parent, {:retry_before_settlement, self()})

            receive do
              {:release_retry_settlement, item} -> {:ok, %{status: :retried, item: item}}
            end
        end
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0, retry_delays_ms: [])
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-retry-handoff-race"))
      payload = %{"idempotency_key" => "retry-handoff-race-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      assert_receive {:initial_retry_item, item}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      assert :ok = DecisionStore.record_transport_async(:failed, item, :send_failed, pid)
      _failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
      assert {:ok, :scheduled} = DecisionStore.retry_dispatch(decision.decision_id, action.action_id, pid)
      assert_receive {:retry_before_settlement, dispatcher_pid}, 1_000

      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
      delivered = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :delivered))
      assert [%{status: :delivered}] = delivered.dispatch_attempts

      send(dispatcher_pid, {:release_retry_settlement, Map.put(item, :status, :pending)})
      Process.sleep(50)
      assert {:ok, settled} = DecisionStore.get(decision.decision_id, pid)
      assert [%{status: :delivered}] = settled.dispatch_attempts
    end

    test "batched queue settlement records every item through one store message", %{dir: dir} do
      parent = self()
      ids = :counters.new(1, [])

      dispatcher = fn dispatched, opts ->
        :ok = :counters.add(ids, 1, 1)
        item_id = 100 + :counters.get(ids, 1)
        item = correlated_queue_item(dispatched, dispatched.answer, opts[:attempt_id], item_id)
        send(parent, {:batch_queue_item, dispatched.decision_id, item})
        {:ok, %{status: :accepted, item: item}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)

      decisions =
        for source <- ["batch-one", "batch-two"] do
          assert {:ok, %{decision: decision}} = request(pid, answerable_request(source))
          payload = %{"idempotency_key" => source, "expected_version" => 1, "option_id" => "ship"}
          assert {:ok, _result} = answer(pid, decision.decision_id, payload)
          decision
        end

      items_by_decision =
        for _index <- 1..2, into: %{} do
          assert_receive {:batch_queue_item, decision_id, item}, 1_000
          {decision_id, item}
        end

      items =
        for decision <- decisions do
          item = Map.fetch!(items_by_decision, decision.decision_id)
          _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
          assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
          item
        end

      assert :ok = DecisionStore.record_transport_batch_async(:consumed, items, nil, pid)

      for decision <- decisions do
        consumed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :consumed))
        assert [%{status: :consumed}] = consumed.dispatch_attempts
      end
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

      assert {:ok, %{decision: advanced}} =
               request(
                 pid,
                 answerable_request("answer-lifecycle")
                 |> Map.merge(%{"question" => "Deploy now with the latest context?", "version" => 2})
               )

      assert advanced.version == 2
      assert Aiur.Decision.active_answer(advanced).action_id == action.action_id

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

      assert_receive {:event, %{topic: "ticket.979.agent.decision.acknowledged", digest_source: :orchestrator} = acknowledged}, 500
      assert EventsDigest.render([acknowledged], "979") =~ "ticket.979.agent.decision.acknowledged"

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

      assert {:ok, %{status: :duplicate, action: ^action}} =
               answer(pid, decision.decision_id, answer_payload)

      changed_answer = Map.put(answer_payload, "option_id", nil) |> Map.put("custom_response", "Different")

      assert {:error, {:conflict, {:idempotency_conflict, action_id}}} =
               answer(pid, decision.decision_id, changed_answer)

      assert action_id == action.action_id
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
      refute Enum.any?(audit, &(audit_type(&1) == :resolved))
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

      assert_receive {:event,
                      %{
                        "question" => "Deploy now?",
                        topic: "ticket.979.agent.decision.requested",
                        digest_source: :orchestrator,
                        id: cursor_event_id
                      } = request_event},
                     500

      assert cursor_event_id > 0
      assert EventsDigest.render([request_event], "979") =~ "ticket.979.agent.decision.requested"

      [persisted] =
        dir
        |> Path.join("decisions.ndjson")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert persisted["event_id"] == "decision-provenance-v1:" <> Integer.to_string(cursor_event_id)
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

  defp supervisor_basis(confidence) do
    %{
      confidence: confidence,
      alternatives_considered: ["Wait"],
      reversibility_belief: :reversible,
      policy_basis: %{
        authority: :supervisor_allowed,
        kind: "architecture",
        reversibility: :reversible,
        checks: %{authority_delegable: true, kind_allowed: true, reversibility_allowed: true},
        allow_non_reversible: false
      }
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
        actor: Map.get(action, :actor) || action |> Map.get(:answer, %{}) |> Map.get(:actor)
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
