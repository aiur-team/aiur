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

  test "an unavailable store is a stable read error", %{store: store} do
    GenServer.stop(store)

    assert {:error, :store_unavailable} = DecisionApi.list(%{}, store: store, policy: @policy)
    assert {:error, :store_unavailable} = DecisionApi.get("dec_missing", store: store, policy: @policy)
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
