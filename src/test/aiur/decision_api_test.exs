defmodule Aiur.DecisionApiTest do
  use ExUnit.Case, async: false

  alias Aiur.{DecisionApi, DecisionStore}

  alias Aiur.DecisionStore.RetainedSnapshot

  alias AiurWeb.OperatorControlCenter.DecisionPresenter

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

    assert {:ok, payload} = DecisionApi.list(%{"limit" => "1"}, store: store, policy: @policy)

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

    assert {:ok, page} = DecisionApi.list(%{limit: 1, cursor: cursor}, store: store, policy: @policy)

    assert page["pagination"]["next_cursor"] == nil
    assert [encoded_older] = page["decisions"]
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
      Aiur.TestSupport.refute_leak(projection, "session-private")
      Aiur.TestSupport.refute_leak(projection, "capability=private")
      Aiur.TestSupport.refute_leak(projection, "account@example.test")
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
end
