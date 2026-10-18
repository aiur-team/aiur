defmodule Aiur.DecisionApiActionsTest do
  use ExUnit.Case, async: false

  alias Aiur.{DecisionApi, DecisionDelegation, DecisionStore}

  @ticket %{identifier: "984", title: "OCC-7", url: "https://github.com/its-everdred/aiur/issues/984"}

  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}

  @policy %{allowed_kinds: ["architecture"], allow_non_reversible: false}

  setup_all do: :ok = Aiur.TestSupport.ensure_runtime_children_running()

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Aiur.TestSupport.tmp_root!("aiur-decision-api")
    Application.put_env(:aiur, :decision_state_dir, dir)

    {:ok, store} = DecisionStore.start_link(name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end)

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

  defmodule RetainedOnlyStore do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok, %{decision: Keyword.fetch!(opts, :decision), report: Keyword.fetch!(opts, :report)}}
    end

    @impl true
    def handle_call({:retained_query, _query}, _from, %{decision: decision} = state) do
      send(state.report, {:retained_api_read, :query})

      {:reply,
       {:ok,
        %{
          decisions: [decision],
          has_next?: false,
          next_key: nil,
          total: 1,
          partial?: false,
          partial_reason: nil,
          counts: %{open: 1, blocking: if(decision.blocking, do: 1, else: 0), total: 1},
          health: :writable
        }}, state}
    end

    def handle_call({:retained_legacy_page, _query, _offset, _limit}, _from, %{decision: decision} = state) do
      send(state.report, {:retained_api_read, :legacy_page})

      {:reply,
       {:ok,
        %{
          decisions: [decision],
          has_next?: false,
          next_key: nil,
          total: 1,
          partial?: false,
          partial_reason: nil,
          counts: %{open: 1, blocking: if(decision.blocking, do: 1, else: 0), total: 1},
          health: :writable
        }}, state}
    end

    def handle_call({:retained_lookup, decision_id}, _from, %{decision: decision} = state) do
      send(state.report, {:retained_api_read, :lookup})
      found = if decision_id == decision.decision_id, do: decision
      {:reply, {:ok, %{decision: found, health: :writable}}, state}
    end

    def handle_call(request, _from, state) do
      send(state.report, {:unexpected_store_read, request})
      {:reply, {:error, :unsupported}, state}
    end
  end

  defmodule MutableLegacySnapshotStore do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, %{snapshot: Keyword.fetch!(opts, :snapshot), mutated: Keyword.fetch!(opts, :mutated), report: Keyword.fetch!(opts, :report)}}

    @impl true
    def handle_call({:retained_legacy_page, _query, _offset, _limit}, _from, state) do
      send(state.report, :legacy_snapshot_read)
      {:reply, {:ok, state.snapshot}, %{state | snapshot: state.mutated}}
    end

    def handle_call(request, _from, state) do
      send(state.report, {:split_snapshot_read, request})
      {:reply, {:error, :unsupported}, state}
    end
  end

  test "list and get use bounded retained-store reads", %{store: store} do
    decision = request!(store, "architecture", :supervisor_allowed, source_id: "retained-only")
    {:ok, retained_store} = RetainedOnlyStore.start_link(decision: decision, report: self())

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(retained_store)
    end)

    assert {:ok, %{"decisions" => [listed]}} =
             DecisionApi.list(%{"limit" => 1}, store: retained_store, policy: @policy)

    assert listed["decision_id"] == decision.decision_id

    assert {:ok, fetched} =
             DecisionApi.get(decision.decision_id, store: retained_store, policy: @policy)

    assert fetched["decision_id"] == decision.decision_id
    assert_receive {:retained_api_read, :legacy_page}, 1000
    assert_receive {:retained_api_read, :lookup}, 1000
    refute_receive {:unexpected_store_read, _request}, 100
  end

  test "legacy offset pages use one retained snapshot across the cursor-page boundary", %{store: store} do
    decisions =
      for index <- 0..100 do
        request!(store, "architecture", :supervisor_allowed,
          source_id: "legacy-snapshot-#{index}",
          now: DateTime.add(~U[2026-07-12 10:00:00Z], index, :second)
        )
      end
      |> Enum.reverse()

    snapshot = retained_snapshot(decisions)
    mutated = retained_snapshot([request!(store, "architecture", :supervisor_allowed, source_id: "legacy-later", now: ~U[2026-07-12 11:00:00Z]) | decisions])
    {:ok, legacy_store} = MutableLegacySnapshotStore.start_link(snapshot: snapshot, mutated: mutated, report: self())

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(legacy_store)
    end)

    assert {:ok, %{"decisions" => rows, "pagination" => %{"total" => 101, "next_offset" => nil}}} =
             DecisionApi.list(%{"limit" => 200}, store: legacy_store, policy: @policy)

    assert Enum.map(rows, & &1["decision_id"]) == Enum.map(decisions, & &1.decision_id)
    assert_receive :legacy_snapshot_read, 1000
    refute_receive {:split_snapshot_read, _request}, 100
  end

  test "get returns one canonical projection and preserves not-found", %{store: store} do
    decision = request!(store, "architecture", :supervisor_allowed, source_id: "known")

    assert {:ok, encoded} = DecisionApi.get(decision.decision_id, store: store, policy: @policy)
    assert encoded["decision_id"] == decision.decision_id
    assert encoded["supervisor_policy"]["allowed"]
    assert encoded["scope"] == %{"kind" => "retained", "label" => "All retained decisions"}

    assert encoded["health"] == %{
             "status" => "available",
             "partial" => false,
             "reason" => nil,
             "label" => "Complete retained Decision data"
           }

    assert {:error, :not_found} = DecisionApi.get("dec_missing", store: store, policy: @policy)
    assert {:error, {:invalid_decision_id, :missing}} = DecisionApi.get("   ", store: store, policy: @policy)

    assert {:error, {:invalid_decision_id, :too_long}} =
             DecisionApi.get(String.duplicate("a", 257), store: store, policy: @policy)
  end

  test "get preserves retained scope and partial health", %{store: store} do
    decision = request!(store, "architecture", :supervisor_allowed, source_id: "partial-detail")
    :sys.replace_state(store, &Map.put(&1, :health, {:corrupt, 2, :invalid_record}))

    assert {:ok, payload} = DecisionApi.get(decision.decision_id, store: store, policy: @policy)
    assert payload["decision_id"] == decision.decision_id
    assert payload["scope"] == %{"kind" => "retained", "label" => "All retained decisions"}

    assert payload["health"] == %{
             "status" => "partial",
             "partial" => true,
             "reason" => "retained_store_partial",
             "label" => "Partial retained Decision data"
           }
  end

  test "enrich delegates a constrained attributed version to the canonical store", %{store: store} do
    decision = request!(store, "architecture", :supervisor_allowed, source_id: "enrich")

    payload = %{
      "expected_version" => 1,
      "context" => %{"short_summary" => "Canonical context"}
    }

    opts = [
      store: store,
      policy: @policy,
      actor: %{kind: :supervisor, id: "supervising-agent"},
      now: ~U[2026-07-12 11:00:00Z]
    ]

    assert {:ok, %{"status" => "accepted", "decision" => enriched}} =
             DecisionApi.enrich(decision.decision_id, payload, opts)

    assert enriched["version"] == 2
    assert enriched["context"]["short_summary"] == "Canonical context"
    assert enriched["supervisor_policy"]["allowed"]

    assert {:ok, %{"status" => "duplicate", "decision" => duplicate}} =
             DecisionApi.enrich(decision.decision_id, payload, opts)

    assert duplicate["version"] == 2
  end

  test "enrich rejects untrusted actor claims and malformed correlation", %{store: store} do
    decision = request!(store, "architecture", :supervisor_allowed, source_id: "enrich-invalid")

    opts = [
      store: store,
      policy: @policy,
      actor: %{kind: :supervisor, id: "supervising-agent"}
    ]

    assert {:error, {:enrichment_invalid, {:forbidden_fields, ["actor"]}}} =
             DecisionApi.enrich(
               decision.decision_id,
               %{"expected_version" => 1, "actor" => %{"kind" => "operator"}},
               opts
             )

    assert {:error, {:invalid_enrichment, {:expected_version, :invalid}}} =
             DecisionApi.enrich(decision.decision_id, %{"expected_version" => "1"}, opts)

    assert {:error, {:invalid_enrichment, {:expected_version, :duplicate}}} =
             DecisionApi.enrich(
               decision.decision_id,
               %{"expected_version" => 1, expected_version: 1},
               opts
             )

    assert {:error, {:invalid_enrichment, {:actor, :untrusted}}} =
             DecisionApi.enrich(
               decision.decision_id,
               %{"expected_version" => 1, "context" => %{"short_summary" => "No"}},
               Keyword.put(opts, :actor, %{kind: :operator, id: "operator-1"})
             )
  end

  test "decide snapshots supervisor reasoning and delegates exactly once to OCC-3", %{store: store} do
    decision = request!(store, "architecture", :supervisor_allowed, source_id: "decide")
    payload = decision_payload()
    opts = supervisor_opts(store)

    assert {:ok, result} = DecisionApi.decide(decision.decision_id, payload, opts)
    assert result["status"] == "accepted"
    assert result["dispatch_status"] == "dispatch_pending"
    assert result["decision"]["decision_status"] == "decided"

    basis = result["action"]["supervisor_basis"]
    assert basis["confidence"] == 91
    assert basis["alternatives_considered"] == ["Wait for OCC-8"]
    assert basis["reversibility_belief"] == "reversible"
    assert basis["policy_basis"]["authority"] == "supervisor_allowed"
    assert basis["policy_basis"]["checks"]["kind_allowed"]

    assert {:ok, replay} = DecisionApi.decide(decision.decision_id, payload, opts)
    assert replay["status"] == "duplicate"
    assert replay["action"]["action_id"] == result["action"]["action_id"]

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.count(audit, &match?(%Aiur.DecisionEvent{type: :answer_recorded}, &1)) == 1
  end

  test "decide denies unsafe policy or incomplete reasoning before answer persistence", %{store: store} do
    human = request!(store, "architecture", :human_required, source_id: "decide-human")

    assert {:error, {:delegation_forbidden, %{reasons: [:human_required]}}} =
             DecisionApi.decide(human.decision_id, decision_payload(), supervisor_opts(store))

    assert {:ok, audit} = DecisionStore.audit_history(human.decision_id, store)
    refute Enum.any?(audit, &match?(%Aiur.DecisionEvent{type: :answer_recorded}, &1))

    eligible = request!(store, "architecture", :supervisor_allowed, source_id: "decide-invalid")
    invalid = Map.delete(decision_payload(), "confidence")

    assert {:error, {:delegation_invalid, {:confidence, :invalid}}} =
             DecisionApi.decide(eligible.decision_id, invalid, supervisor_opts(store))

    forged = Map.put(decision_payload(), "actor", %{"kind" => "operator"})

    assert {:error, {:delegation_invalid, {:forbidden_fields, ["actor"]}}} =
             DecisionApi.decide(eligible.decision_id, forged, supervisor_opts(store))

    assert {:ok, current} = DecisionStore.get(eligible.decision_id, store)
    assert current.answer == nil
  end

  test "the serialized writer rejects supervisor basis from a different request version", %{store: store} do
    v1 = request!(store, "architecture", :supervisor_allowed, source_id: "policy-race")
    payload = Map.put(decision_payload(), "expected_version", 2)

    assert {:ok, delegation} = DecisionDelegation.normalize(v1, payload, @policy)

    assert {:ok, %{decision: v2}} =
             DecisionStore.request(
               %{
                 "version" => 2,
                 "source_id" => "policy-race",
                 "question" => "Choose policy-race?",
                 "blocking" => true,
                 "kind" => "architecture",
                 "authority" => "human_required",
                 "context" => %{"authority_basis" => "security"},
                 "reversibility" => "reversible"
               },
               [ticket: @ticket, source: @source, now: ~U[2026-07-12 10:30:00Z]],
               store
             )

    assert v2.authority == :human_required

    assert {:error, {:answer_invalid, {:supervisor_basis, :decision_mismatch}}} =
             DecisionStore.answer(
               v2.decision_id,
               delegation.answer_payload,
               [
                 actor: %{kind: :supervisor, id: "supervising-agent"},
                 supervisor_basis: delegation.basis,
                 now: ~U[2026-07-12 11:00:00Z]
               ],
               store
             )

    assert {:ok, current} = DecisionStore.get(v2.decision_id, store)
    assert current.answer == nil

    assert {:ok, %{action: original}} =
             DecisionStore.answer(
               v2.decision_id,
               %{
                 "expected_version" => 2,
                 "idempotency_key" => "policy-race-original",
                 "custom_response" => "Human direction",
                 "rationale" => "Operator chose the current version"
               },
               [actor: %{kind: :operator, id: "operator-1"}],
               store
             )

    revision_payload =
      original
      |> revision_payload()
      |> Map.put("expected_version", 2)

    assert {:ok, revision_delegation} =
             DecisionDelegation.normalize_revision(v1, revision_payload, @policy)

    assert {:error, {:revision_invalid, {:answer_invalid, {:supervisor_basis, :decision_mismatch}}}} =
             DecisionStore.revise(
               v2.decision_id,
               revision_delegation.answer_payload,
               [
                 actor: %{kind: :supervisor, id: "supervising-agent"},
                 supervisor_basis: revision_delegation.basis,
                 now: ~U[2026-07-12 11:01:00Z]
               ],
               store
             )

    assert {:ok, audit} = DecisionStore.audit_history(v2.decision_id, store)
    refute Enum.any?(audit, &match?(%Aiur.DecisionEvent{type: :revision_recorded}, &1))
  end

  defp decision_payload do
    %{
      "idempotency_key" => "supervisor-decide-1",
      "expected_version" => 1,
      "custom_response" => "Use the canonical path",
      "rationale" => "It preserves one append-only lifecycle.",
      "confidence" => 91,
      "alternatives_considered" => ["Wait for OCC-8"],
      "reversibility_belief" => "reversible"
    }
  end

  defp revision_payload(original) do
    %{
      "expected_version" => 1,
      "expected_action_id" => original.action_id,
      "expected_revision_sequence" => 0,
      "idempotency_key" => "supervisor-revision-1",
      "custom_response" => "Use the corrected path",
      "rationale" => "New production evidence",
      "confidence" => 88,
      "alternatives_considered" => ["Keep the original direction"],
      "reversibility_belief" => "reversible"
    }
  end

  defp supervisor_opts(store) do
    [
      store: store,
      policy: @policy,
      actor: %{kind: :supervisor, id: "supervising-agent"},
      now: ~U[2026-07-12 11:00:00Z]
    ]
  end

  defp request!(store, kind, authority, opts) do
    source_id = Keyword.fetch!(opts, :source_id)
    now = Keyword.get(opts, :now, ~U[2026-07-12 10:00:00Z])
    blocking = Keyword.get(opts, :blocking, true)

    payload = %{
      "source_id" => source_id,
      "question" => "Choose #{source_id}?",
      "blocking" => blocking,
      "kind" => kind,
      "authority" => Atom.to_string(authority),
      "context" => if(authority == :human_required, do: %{"authority_basis" => if(kind == "product", do: "product", else: "security")}, else: nil),
      "reversibility" => "reversible"
    }

    payload =
      case Keyword.get(opts, :version) do
        nil -> payload
        version -> Map.put(payload, "version", version)
      end

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(payload, [ticket: @ticket, source: @source, now: now], store)

    decision
  end

  defp retained_snapshot(decisions) do
    %{
      decisions: decisions,
      has_next?: false,
      next_key: nil,
      total: length(decisions),
      partial?: false,
      partial_reason: nil,
      counts: %{open: length(decisions), blocking: Enum.count(decisions, & &1.blocking), total: length(decisions)},
      health: :writable
    }
  end
end
