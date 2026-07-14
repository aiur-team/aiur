defmodule AiurWeb.OperatorControlCenter.DecisionProviderTest do
  use ExUnit.Case, async: false

  alias Aiur.{DecisionStore, SecretRedactor}
  alias AiurWeb.OperatorControlCenter.{DecisionPresenter, DecisionProvider}

  @ticket %{identifier: "1088", title: "Retained Decisions", url: "https://example.test/issues/1088"}
  @source %{agent_id: "agent-1088", session_id: "session-private", event_id: "event-private"}

  defmodule TargetedMetrics do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, %{snapshots: Keyword.fetch!(opts, :snapshots), report: Keyword.fetch!(opts, :report)}}

    @impl true
    def handle_call({:snapshot, decision_id}, _from, state) do
      send(state.report, {:metric_snapshot, decision_id})
      {:reply, Map.get(state.snapshots, decision_id, {:error, :unavailable}), state}
    end
  end

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
    captured_at = ~U[2026-07-14 14:30:00Z]

    provenance = %{
      schema_version: 1,
      agent_family: "codex",
      backend: "openai",
      requested_model: "gpt-5",
      resolved_model: "gpt-5.6",
      session_id: "session-private",
      attempt_id: "attempt-1088",
      source: "agent_runner",
      captured_at: captured_at
    }

    safe_artifact = %{kind: :path, value: "/safe/artifacts/evidence.log"}

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
            },
            source:
              Map.merge(current.source, %{
                account_id: "account-private",
                capability_url: "https://github.com/its-everdred/aiur?capability=private",
                credential: secret,
                prompt: "raw system prompt"
              }),
            artifacts: [
              safe_artifact,
              %{kind: :url, value: "https://github.com/its-everdred/aiur/evidence"},
              %{kind: :url, value: "https://github.com/its-everdred/aiur/evidence?capability=private"},
              %{kind: :url, value: "https://github.com/its-everdred/aiur/evidence#capability=private"}
            ],
            provenance: provenance
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
    assert detail.artifacts == [safe_artifact, %{kind: :url, value: "https://github.com/its-everdred/aiur/evidence"}]

    assert detail.provenance ==
             Map.drop(provenance, [:session_id])

    assert {:ok, %{decisions: [row]}} =
             DecisionProvider.list(%{"limit" => 1},
               decision_store: store,
               decision_metrics: make_ref()
             )

    assert row.source == detail.source
    assert row.artifacts == detail.artifacts
    assert row.provenance == detail.provenance

    for private_value <- [
          "session-private",
          "event-private",
          "account-private",
          "invocation-private",
          "raw system prompt",
          "https://github.com/its-everdred/aiur?capability=private",
          "evidence?capability=private",
          "evidence#capability=private",
          secret
        ] do
      refute inspect(detail) =~ private_value
      refute inspect(row) =~ private_value
    end
  end

  test "list fetches latency only for the bounded returned page", %{store: store} do
    oldest = request!(store, "metrics-oldest", ~U[2026-07-13 08:00:00Z])
    middle = request!(store, "metrics-middle", ~U[2026-07-13 08:01:00Z])
    newest = request!(store, "metrics-newest", ~U[2026-07-13 08:02:00Z])

    {:ok, metrics} =
      TargetedMetrics.start_link(
        snapshots: %{
          oldest.decision_id => %{decision_id: oldest.decision_id},
          middle.decision_id => %{decision_id: middle.decision_id},
          newest.decision_id => %{decision_id: newest.decision_id}
        },
        report: self()
      )

    assert {:ok, %{decisions: [row], pagination: %{total: 3}}} =
             DecisionProvider.list(%{"limit" => 1}, decision_store: store, decision_metrics: metrics)

    assert row.decision_id == newest.decision_id
    assert_receive {:metric_snapshot, newest_id}
    assert newest_id == newest.decision_id
    refute_receive {:metric_snapshot, _other_id}
  end

  test "list stops latency enrichment after the first unavailable metric snapshot", %{store: store} do
    request!(store, "metrics-oldest", ~U[2026-07-13 08:00:00Z])
    request!(store, "metrics-middle", ~U[2026-07-13 08:01:00Z])
    newest = request!(store, "metrics-newest", ~U[2026-07-13 08:02:00Z])

    {:ok, metrics} = TargetedMetrics.start_link(snapshots: %{}, report: self())

    assert {:ok, %{decisions: rows}} =
             DecisionProvider.list(%{"limit" => 3}, decision_store: store, decision_metrics: metrics)

    assert Enum.map(rows, & &1.latency) == List.duplicate(%{status: :unavailable, snapshot: nil}, 3)
    assert_receive {:metric_snapshot, newest_id}
    assert newest_id == newest.decision_id
    refute_receive {:metric_snapshot, _other_id}
  end

  test "exact retained detail keeps partial health without turning a missing ID into an outage", %{store: store} do
    decision = request!(store, "partial-detail", ~U[2026-07-13 08:00:00Z])
    :sys.replace_state(store, &Map.put(&1, :health, {:corrupt, 2, :invalid_record}))

    assert {:ok, %{decision: detail, health: %{status: :partial, partial?: true}}} =
             DecisionProvider.detail(decision.decision_id, decision_store: store, decision_metrics: make_ref())

    assert detail.decision_id == decision.decision_id

    assert {:error, {:indeterminate, %{status: :partial, partial?: true}}} =
             DecisionProvider.detail("dec_missing", decision_store: store, decision_metrics: make_ref())
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

    assert {:ok, %{open: nil, blocking: nil, total: nil, health: %{status: :unavailable, partial?: true}}} =
             DecisionProvider.counts(decision_store: unavailable_store)
  end

  defp request!(store, source_id, now) do
    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{
                 "source_id" => source_id,
                 "question" => "Should #{source_id} ship?",
                 "blocking" => false,
                 "reversibility" => "reversible"
               },
               [ticket: @ticket, source: @source, now: now],
               store
             )

    decision
  end
end
