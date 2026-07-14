defmodule AiurWeb.OperatorControlCenter.DecisionProviderTest do
  use ExUnit.Case, async: false

  alias Aiur.{DecisionStore, SecretRedactor}
  alias AiurWeb.OperatorControlCenter.{DecisionPresenter, DecisionProvider}

  @ticket %{identifier: "1088", title: "Retained Decisions", url: "https://example.test/issues/1088"}
  @source %{agent_id: "agent-1088", session_id: "session-private", event_id: "event-private"}

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Path.join(System.tmp_dir!(), "aiur-decision-provider-#{System.unique_integer([:positive])}")
    Application.put_env(:aiur, :decision_state_dir, dir)
    {:ok, store} = DecisionStore.start_link(name: nil, filesystem_sync_fun: fn -> :ok end)

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

  test "detail and retained rows share presentation, lifecycle, latency, and sanitization", %{store: store} do
    secret = "ghp_" <> String.duplicate("a", 36)

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{
                 "source_id" => "provider-parity",
                 "question" => "Can #{secret} be rendered?",
                 "blocking" => true,
                 "reversibility" => "reversible"
               },
               [ticket: @ticket, source: @source, now: ~U[2026-07-13 08:00:00Z]],
               store
             )

    :sys.replace_state(store, fn state ->
      update_in(state, [:current, decision.decision_id], fn current ->
        %{
          current
          | acknowledgement: %{
              action_id: "action-1088",
              actor: %{kind: :agent, id: "account-private"},
              source: %{agent_id: "agent-1088", session_id: "session-private", invocation_id: "invocation-private"},
              occurred_at: ~U[2026-07-13 08:01:00Z]
            }
        }
      end)
    end)

    {:ok, current} = DecisionStore.get(decision.decision_id, store)
    [overview] = DecisionPresenter.rows([current])

    assert {:ok, %{decision: detail, health: %{status: :available}}} =
             DecisionProvider.detail(decision.decision_id, decision_store: store, decision_metrics: make_ref())

    assert Map.delete(detail, :latency) == overview
    assert detail.latency == %{status: :unavailable, snapshot: nil}
    assert detail.question == SecretRedactor.redact("Can #{secret} be rendered?")
    refute Map.has_key?(detail.source, :session_id)
    refute Map.has_key?(detail.source, :event_id)

    assert {:ok, %{decisions: [row]}} = DecisionProvider.list(%{"limit" => 1}, decision_store: store, decision_metrics: make_ref())
    assert row.source == detail.source
    refute inspect(row) =~ "session-private"
    refute inspect(row) =~ "event-private"
    refute inspect(row) =~ "account-private"
    refute inspect(row) =~ "invocation-private"
  end

  test "provider failure preserves retained scope and marks results unavailable" do
    unavailable_store = make_ref()

    assert {:error, :store_unavailable} =
             DecisionProvider.detail("dec_missing", decision_store: unavailable_store, decision_metrics: make_ref())

    assert {:ok,
            %{
              decisions: [],
              health: %{status: :unavailable, partial?: true},
              partial_results?: true,
              pagination: %{total: nil}
            }} =
             DecisionProvider.list(%{"limit" => 1}, decision_store: unavailable_store, decision_metrics: make_ref())

    assert {:ok, %{open: nil, blocking: nil, health: %{status: :unavailable, partial?: true}}} =
             DecisionProvider.counts(decision_store: unavailable_store)
  end
end
