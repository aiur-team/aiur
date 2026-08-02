defmodule Aiur.DecisionApiTest do
  use ExUnit.Case, async: false

  alias Aiur.{DecisionApi, DecisionDelegation, DecisionStore}
  alias Aiur.DecisionStore.RetainedSnapshot
  alias AiurWeb.OperatorControlCenter.DecisionPresenter

  @ticket %{identifier: "984", title: "OCC-7", url: "https://github.com/its-everdred/aiur/issues/984"}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}
  @policy %{allowed_kinds: ["architecture"], allow_non_reversible: false}

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

  defmodule SnapshotLegacyStore do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      current = Map.new(Keyword.fetch!(opts, :decisions), &{&1.decision_id, &1})
      {:ok, %{current: current, index: RetainedSnapshot.build_index(current)}}
    end

    @impl true
    def handle_call({:retained_legacy_page, query, offset, limit}, _from, state) do
      reply =
        RetainedSnapshot.legacy_page(
          state.current,
          state.index,
          :writable,
          Map.put(query, :limit, limit),
          offset
        )

      {:reply, reply, state}
    end
  end

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Path.join(System.tmp_dir!(), "aiur-decision-api-#{System.unique_integer([:positive])}")
    Application.put_env(:aiur, :decision_state_dir, dir)

    {:ok, store} =
      DecisionStore.start_link(
        name: nil,
        filesystem_sync_fun: fn -> :ok end
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

  test "list returns cursor-stable canonical projections with current policy evaluation", %{store: store} do
    older =
      request!(store, "architecture", :supervisor_allowed,
        source_id: "older",
        now: ~U[2026-07-12 10:00:00Z]
      )

    newer =
      request!(store, "product", :human_required,
        source_id: "newer",
        now: ~U[2026-07-12 11:00:00Z]
      )

    assert {:ok, payload} =
             DecisionApi.list(%{"limit" => "1"}, store: store, policy: @policy)

    assert %{
             "limit" => 1,
             "cursor" => nil,
             "next_cursor" => cursor,
             "total" => 2,
             "partial_reason" => nil
           } = payload["pagination"]

    assert is_binary(cursor)
    assert [encoded] = payload["decisions"]
    assert encoded["decision_id"] == newer.decision_id
    assert encoded["question"] == newer.question
    assert encoded["supervisor_policy"]["allowed"] == false
    assert encoded["supervisor_policy"]["reasons"] == ["human_required", "kind_not_allowed"]

    assert {:ok, second_page} =
             DecisionApi.list(%{limit: 1, cursor: cursor}, store: store, policy: @policy)

    assert second_page["pagination"]["next_cursor"] == nil
    assert [encoded_older] = second_page["decisions"]
    assert encoded_older["decision_id"] == older.decision_id
    assert encoded_older["supervisor_policy"]["allowed"]

    refute Map.has_key?(encoded_older["supervisor_policy"], "allowed_kinds")
  end

  test "list and get expose only the bounded public Decision projection", %{store: store} do
    decision = request!(store, "architecture", :supervisor_allowed, source_id: "public-boundary")

    :sys.replace_state(store, fn state ->
      unsafe = %{
        Map.fetch!(state.current, decision.decision_id)
        | ticket: %{
            identifier: "984",
            title: "OCC-7",
            url: "https://operator:credential@example.test/issues/984?capability=private#fragment"
          },
          source: %{agent_id: "agent-1", session_id: "session-private", event_id: "event-private"},
          artifacts: [
            %{kind: :url, value: "https://example.test/evidence"},
            %{kind: :url, value: "https://example.test/evidence?capability=private#fragment"}
          ],
          provenance: %{
            schema_version: 1,
            agent_family: "codex",
            backend: nil,
            requested_model: "model-safe",
            resolved_model: "model-safe",
            attempt_id: "attempt-safe",
            source: "supervisor",
            session_id: "session-private",
            capability_url: "https://example.test?token=private"
          },
          legacy_attention: %{session_id: "session-private"}
      }

      current = Map.put(state.current, decision.decision_id, unsafe)
      %{state | current: current, retained_index: RetainedSnapshot.build_index(current)}
    end)

    assert {:ok, %{"decisions" => [listed]}} = DecisionApi.list(%{}, store: store, policy: @policy)
    assert {:ok, fetched} = DecisionApi.get(decision.decision_id, store: store, policy: @policy)
    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    [presented] = DecisionPresenter.rows([current])

    assert fetched["ticket"] == %{"identifier" => presented.ticket.identifier, "title" => presented.ticket.title, "url" => presented.ticket.url}
    assert fetched["source"]["agent_id"] == presented.source.agent_id
    assert fetched["artifacts"] == Enum.map(presented.artifacts, &%{"kind" => Atom.to_string(&1.kind), "value" => &1.value})

    assert Map.reject(fetched["provenance"], fn {_key, value} -> is_nil(value) end) ==
             presented.provenance
             |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
             |> Map.reject(fn {_key, value} -> is_nil(value) end)

    assert Map.has_key?(presented.provenance, :backend)
    assert presented.provenance.backend == nil

    for projection <- [listed, fetched] do
      assert projection["ticket"]["url"] == nil
      assert projection["source"] == %{"agent_id" => "agent-1"}
      assert projection["artifacts"] == [%{"kind" => "url", "value" => "https://example.test/evidence"}]
      refute Map.has_key?(projection, "source_id")
      refute Map.has_key?(projection, "content_hash")
      refute Map.has_key?(projection, "legacy_attention")
      refute Map.has_key?(projection["provenance"], "session_id")
      refute inspect(projection) =~ "session-private"
      refute inspect(projection) =~ "capability=private"
      refute inspect(projection) =~ "account@example.test"
    end
  end

  test "v1 list preserves documented offset defaults and bounds", %{store: store} do
    oldest =
      request!(store, "architecture", :supervisor_allowed,
        source_id: "legacy-oldest",
        now: ~U[2026-07-12 10:00:00Z]
      )

    middle =
      request!(store, "architecture", :supervisor_allowed,
        source_id: "legacy-middle",
        now: ~U[2026-07-12 10:01:00Z]
      )

    newest =
      request!(store, "architecture", :supervisor_allowed,
        source_id: "legacy-newest",
        now: ~U[2026-07-12 10:02:00Z]
      )

    assert {:ok, default_page} = DecisionApi.list(%{}, store: store, policy: @policy)

    assert %{"limit" => 50, "offset" => 0, "next_offset" => nil, "total" => 3} =
             default_page["pagination"]

    assert Enum.map(default_page["decisions"], & &1["decision_id"]) == [
             newest.decision_id,
             middle.decision_id,
             oldest.decision_id
           ]

    assert {:ok, max_page} =
             DecisionApi.list(%{"limit" => "200", "offset" => "1"}, store: store, policy: @policy)

    assert %{"limit" => 200, "offset" => 1, "next_offset" => nil, "total" => 3} =
             max_page["pagination"]

    assert Enum.map(max_page["decisions"], & &1["decision_id"]) == [
             middle.decision_id,
             oldest.decision_id
           ]

    assert {:ok, offset_page} =
             DecisionApi.list(%{"limit" => "1", "offset" => "1"}, store: store, policy: @policy)

    assert %{"limit" => 1, "offset" => 1, "next_offset" => 2} = offset_page["pagination"]
    assert [offset_decision] = offset_page["decisions"]
    assert offset_decision["decision_id"] == middle.decision_id
  end

  test "list preserves retained policy filters through offset-compatible page reads", %{store: store} do
    architecture =
      request!(store, "Architecture", :supervisor_preferred,
        source_id: "architecture",
        blocking: true
      )

    _product =
      request!(store, "product", :human_required,
        source_id: "product",
        blocking: false
      )

    filters = %{
      "authority" => "supervisor_preferred",
      "blocking" => "true",
      "kind" => "architecture",
      "ticket" => "984"
    }

    assert {:ok, %{"decisions" => [encoded], "pagination" => %{"total" => 1}}} =
             DecisionApi.list(filters, store: store, policy: @policy)

    assert encoded["decision_id"] == architecture.decision_id
  end

  test "legacy ticket filters compare the complete ticket identifier", %{store: store} do
    ticket_ten = request!(store, "architecture", :supervisor_allowed, source_id: "ticket-ten")
    ticket_1088 = request!(store, "architecture", :supervisor_allowed, source_id: "ticket-1088")

    :sys.replace_state(store, fn state ->
      current =
        state.current
        |> Map.update!(ticket_ten.decision_id, &%{&1 | ticket: %{&1.ticket | identifier: "10"}})
        |> Map.update!(ticket_1088.decision_id, &%{&1 | ticket: %{&1.ticket | identifier: "1088"}})

      %{state | current: current, retained_index: RetainedSnapshot.build_index(current)}
    end)

    assert {:ok, %{"decisions" => [encoded]}} = DecisionApi.list(%{"ticket" => "10"}, store: store, policy: @policy)
    assert encoded["decision_id"] == ticket_ten.decision_id
  end

  test "legacy offset pages retain current created-at ordering after a Decision update", %{store: store} do
    first =
      request!(store, "architecture", :supervisor_allowed,
        source_id: "legacy-updated",
        now: ~U[2026-07-12 10:00:00Z]
      )

    middle =
      request!(store, "architecture", :supervisor_allowed,
        source_id: "legacy-middle",
        now: ~U[2026-07-12 10:01:00Z]
      )

    updated =
      request!(store, "architecture", :supervisor_allowed,
        source_id: "legacy-updated",
        version: 2,
        now: ~U[2026-07-12 10:02:00Z]
      )

    assert updated.decision_id == first.decision_id

    assert {:ok, %{"decisions" => [first_page]}} =
             DecisionApi.list(%{"limit" => 1}, store: store, policy: @policy)

    assert first_page["decision_id"] == updated.decision_id

    assert {:ok, %{"decisions" => decisions}} = DecisionApi.list(%{}, store: store, policy: @policy)
    assert Enum.map(decisions, & &1["decision_id"]) == [updated.decision_id, middle.decision_id]
  end

  test "filtered legacy offsets remain reachable beyond the bounded cursor scan", %{store: store} do
    seed = request!(store, "architecture", :supervisor_preferred, source_id: "legacy-filtered-seed")
    base_time = ~U[2026-07-12 10:00:00Z]

    decisions =
      for index <- 0..1_100 do
        %{seed | decision_id: "dec_legacy_filtered_#{index}", created_at: DateTime.add(base_time, index * 2, :second)}
      end
      |> Enum.sort_by(&{DateTime.to_unix(&1.created_at, :microsecond), &1.decision_id}, :desc)

    nonmatching =
      for index <- 0..100 do
        %{
          seed
          | decision_id: "dec_legacy_nonmatching_#{index}",
            authority: :human_required,
            created_at: DateTime.add(base_time, index * 20 + 1, :second)
        }
      end

    {:ok, legacy_store} = SnapshotLegacyStore.start_link(decisions: decisions ++ nonmatching)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(legacy_store)
    end)

    assert {:ok, first_page} =
             DecisionApi.list(
               %{"authority" => "supervisor_preferred", "limit" => 200, "offset" => 900},
               store: legacy_store,
               policy: @policy
             )

    assert first_page["partial_results"] == false
    assert first_page["pagination"]["next_offset"] == 1_100

    assert Enum.map(first_page["decisions"], & &1["decision_id"]) ==
             decisions |> Enum.drop(900) |> Enum.take(200) |> Enum.map(& &1.decision_id)

    assert {:ok, final_page} =
             DecisionApi.list(
               %{"authority" => "supervisor_preferred", "limit" => 200, "offset" => 1_100},
               store: legacy_store,
               policy: @policy
             )

    assert final_page["partial_results"] == false

    assert final_page["pagination"] == %{
             "limit" => 200,
             "offset" => 1_100,
             "next_offset" => nil,
             "cursor" => nil,
             "next_cursor" => nil,
             "total" => 1_101,
             "partial_reason" => nil,
             "label" => "Final retained Decision page of up to 200"
           }

    assert Enum.map(final_page["decisions"], & &1["decision_id"]) ==
             decisions |> Enum.drop(1_100) |> Enum.map(& &1.decision_id)
  end

  test "malformed or unknown list parameters fail rather than broadening the result", %{store: store} do
    request!(store, "architecture", :supervisor_allowed, source_id: "one")

    invalid_params = [
      %{"limit" => 0},
      %{"limit" => 201},
      %{"offset" => -1},
      %{"offset" => 1_000_001},
      %{"blocking" => "yes"},
      %{"authority" => "future"},
      %{"ticket" => ""},
      %{"unknown" => "ignored"},
      %{"kind" => "architecture", kind: "product"},
      []
    ]

    for params <- invalid_params do
      assert {:error, {:invalid_list, _reason}} =
               DecisionApi.list(params, store: store, policy: @policy)
    end

    assert {:ok, %{counts: %{total: 1}}} = DecisionStore.retained_counts(store)
  end

  test "cursor pages do not duplicate or skip when an insertion arrives between API reads", %{store: store} do
    oldest = request!(store, "architecture", :supervisor_allowed, source_id: "cursor-oldest", now: ~U[2026-07-12 10:00:00Z])
    middle = request!(store, "architecture", :supervisor_allowed, source_id: "cursor-middle", now: ~U[2026-07-12 10:01:00Z])
    newest = request!(store, "architecture", :supervisor_allowed, source_id: "cursor-newest", now: ~U[2026-07-12 10:02:00Z])

    assert {:ok, %{"decisions" => [first], "pagination" => %{"next_cursor" => cursor}}} =
             DecisionApi.list(%{"limit" => 1}, store: store, policy: @policy)

    assert first["decision_id"] == newest.decision_id

    _later =
      request!(store, "architecture", :supervisor_allowed,
        source_id: "cursor-later",
        now: ~U[2026-07-12 10:03:00Z]
      )

    assert {:ok, %{"decisions" => [second], "pagination" => %{"next_cursor" => next_cursor}}} =
             DecisionApi.list(%{"limit" => 1, "cursor" => cursor}, store: store, policy: @policy)

    assert second["decision_id"] == middle.decision_id

    assert {:ok, %{"decisions" => [third], "pagination" => %{"next_cursor" => nil}}} =
             DecisionApi.list(%{"limit" => 1, "cursor" => next_cursor}, store: store, policy: @policy)

    assert third["decision_id"] == oldest.decision_id
    assert MapSet.size(MapSet.new([first["decision_id"], second["decision_id"], third["decision_id"]])) == 3
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
    assert_receive {:retained_api_read, :legacy_page}
    assert_receive {:retained_api_read, :lookup}
    refute_receive {:unexpected_store_read, _request}
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
    assert_receive :legacy_snapshot_read
    refute_receive {:split_snapshot_read, _request}
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

  test "revise delegates to OCC-8 with trusted actor and policy basis", %{store: store} do
    decision = request!(store, "architecture", :supervisor_allowed, source_id: "revise")

    assert {:ok, %{action: original}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "expected_version" => 1,
                 "idempotency_key" => "original-answer",
                 "custom_response" => "Use the original path",
                 "rationale" => "Initial evidence"
               },
               [actor: %{kind: :operator, id: "operator-1"}, now: ~U[2026-07-12 10:30:00Z]],
               store
             )

    payload = revision_payload(original)
    opts = supervisor_opts(store)

    assert {:ok, result} = DecisionApi.revise(decision.decision_id, payload, opts)
    assert result["status"] == "accepted"
    assert result["revision_result"] == "recorded"
    assert result["action"]["prior_action_id"] == original.action_id
    assert result["action"]["answer"]["actor"] == %{"kind" => "supervisor", "id" => "supervising-agent"}

    basis = result["action"]["answer"]["supervisor_basis"]
    assert basis["confidence"] == 88
    assert basis["policy_basis"]["authority"] == "supervisor_allowed"
    assert basis["policy_basis"]["checks"]["kind_allowed"]

    assert {:ok, replay} = DecisionApi.revise(decision.decision_id, payload, opts)
    assert replay["status"] == "duplicate"
    assert replay["action"]["action_id"] == result["action"]["action_id"]

    assert {:error, {:conflict, {:idempotency_conflict, _action_id}}} =
             DecisionApi.revise(
               decision.decision_id,
               Map.put(payload, "custom_response", "Conflicting correction"),
               opts
             )

    stale =
      payload
      |> Map.put("idempotency_key", "revise-stale")
      |> Map.put("custom_response", "Another correction")

    assert {:error, {:conflict, {:stale_action, _correlation}}} =
             DecisionApi.revise(decision.decision_id, stale, opts)

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.count(audit, &match?(%Aiur.DecisionEvent{type: :revision_recorded}, &1)) == 1
  end

  test "the API keeps confidence endpoints as integer supervisor basis values", %{store: store} do
    decision = request!(store, "architecture", :supervisor_allowed, source_id: "confidence-boundaries")

    answer_payload =
      decision_payload()
      |> Map.put("idempotency_key", "confidence-zero")
      |> Map.put("confidence", 0)

    assert {:ok, answered} = DecisionApi.decide(decision.decision_id, answer_payload, supervisor_opts(store))
    assert answered["action"]["supervisor_basis"]["confidence"] == 0

    revision_payload = %{
      "expected_version" => 1,
      "expected_action_id" => answered["action"]["action_id"],
      "expected_revision_sequence" => 0,
      "idempotency_key" => "confidence-hundred",
      "custom_response" => "Use the corrected path",
      "rationale" => "New production evidence",
      "confidence" => 100,
      "alternatives_considered" => ["Keep the original direction"],
      "reversibility_belief" => "reversible"
    }

    assert {:ok, revised} = DecisionApi.revise(decision.decision_id, revision_payload, supervisor_opts(store))
    assert revised["action"]["answer"]["supervisor_basis"]["confidence"] == 100

    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert current.answer.supervisor_basis.confidence == 0
    assert hd(current.revisions).answer.supervisor_basis.confidence == 100
  end

  test "revise denies unsafe, forged, or incomplete calls before OCC-8 persistence", %{store: store} do
    human = request!(store, "architecture", :human_required, source_id: "revise-human")

    assert {:error, {:delegation_forbidden, %{reasons: [:human_required]}}} =
             DecisionApi.revise(human.decision_id, %{}, supervisor_opts(store))

    eligible = request!(store, "architecture", :supervisor_allowed, source_id: "revise-eligible")

    assert {:error, {:delegation_invalid, {:forbidden_fields, ["actor", "authority"]}}} =
             DecisionApi.revise(
               eligible.decision_id,
               %{"actor" => %{}, "authority" => "human_required"},
               supervisor_opts(store)
             )

    incomplete =
      %{
        "expected_version" => 1,
        "expected_action_id" => "act_original",
        "expected_revision_sequence" => 0,
        "idempotency_key" => "revision-incomplete",
        "custom_response" => "Corrected",
        "rationale" => "New evidence",
        "alternatives_considered" => [],
        "reversibility_belief" => "reversible"
      }

    assert {:error, {:delegation_invalid, {:confidence, :invalid}}} =
             DecisionApi.revise(eligible.decision_id, incomplete, supervisor_opts(store))
  end

  test "an unavailable store is a stable read error", %{store: store} do
    GenServer.stop(store)

    assert {:error, :store_unavailable} = DecisionApi.list(%{}, store: store, policy: @policy)
    assert {:error, :store_unavailable} = DecisionApi.get("dec_missing", store: store, policy: @policy)

    assert {:error, :store_unavailable} =
             DecisionApi.enrich(
               "dec_missing",
               %{"expected_version" => 1, "context" => %{"short_summary" => "No store"}},
               store: store,
               actor: %{kind: :supervisor, id: "supervising-agent"}
             )

    assert {:error, :store_unavailable} =
             DecisionApi.decide("dec_missing", decision_payload(), supervisor_opts(store))

    assert {:error, :store_unavailable} =
             DecisionApi.revise("dec_missing", %{}, supervisor_opts(store))
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
