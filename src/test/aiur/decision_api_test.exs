defmodule Aiur.DecisionApiTest do
  use ExUnit.Case, async: false

  alias Aiur.{DecisionApi, DecisionStore}

  @ticket %{identifier: "984", title: "OCC-7", url: "https://github.com/its-everdred/aiur/issues/984"}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}
  @policy %{allowed_kinds: ["architecture"], allow_non_reversible: false}

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
      if Process.alive?(store), do: GenServer.stop(store)

      case original_override do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      File.rm_rf!(dir)
    end)

    %{store: store}
  end

  test "list returns deterministic canonical projections with current policy evaluation", %{store: store} do
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
             DecisionApi.list(%{"limit" => "1", "offset" => "0"}, store: store, policy: @policy)

    assert payload["pagination"] == %{"limit" => 1, "next_offset" => 1, "offset" => 0, "total" => 2}
    assert [encoded] = payload["decisions"]
    assert encoded["decision_id"] == newer.decision_id
    assert encoded["question"] == newer.question
    assert encoded["supervisor_policy"]["allowed"] == false
    assert encoded["supervisor_policy"]["reasons"] == ["human_required", "kind_not_allowed"]

    assert {:ok, second_page} =
             DecisionApi.list(%{limit: 1, offset: 1}, store: store, policy: @policy)

    assert second_page["pagination"]["next_offset"] == nil
    assert [encoded_older] = second_page["decisions"]
    assert encoded_older["decision_id"] == older.decision_id
    assert encoded_older["supervisor_policy"]["allowed"]

    refute Map.has_key?(encoded_older["supervisor_policy"], "allowed_kinds")
  end

  test "list validates and applies only the documented filters", %{store: store} do
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

  test "malformed or unknown list parameters fail rather than broadening the result", %{store: store} do
    request!(store, "architecture", :supervisor_allowed, source_id: "one")

    invalid_params = [
      %{"limit" => 0},
      %{"limit" => 201},
      %{"offset" => -1},
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

    assert length(DecisionStore.list(store)) == 1
  end

  test "get returns one canonical projection and preserves not-found", %{store: store} do
    decision = request!(store, "architecture", :supervisor_allowed, source_id: "known")

    assert {:ok, encoded} = DecisionApi.get(decision.decision_id, store: store, policy: @policy)
    assert encoded["decision_id"] == decision.decision_id
    assert encoded["supervisor_policy"]["allowed"]

    assert {:error, :not_found} = DecisionApi.get("dec_missing", store: store, policy: @policy)
    assert {:error, {:invalid_decision_id, :missing}} = DecisionApi.get("   ", store: store, policy: @policy)

    assert {:error, {:invalid_decision_id, :too_long}} =
             DecisionApi.get(String.duplicate("a", 257), store: store, policy: @policy)
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

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(payload, [ticket: @ticket, source: @source, now: now], store)

    decision
  end
end
