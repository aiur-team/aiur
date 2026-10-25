defmodule Aiur.Extensions.DashboardDecisionTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  @endpoint AiurWeb.Endpoint

  import Aiur.ExtensionsTestSupport
  alias Aiur.ExtensionsTestSupport.StaticOrchestrator

  defmodule StaticDecisionStore do
    use GenServer

    alias Aiur.DecisionStore.RetainedSnapshot

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :decisions), name: name)
    end

    def init(decisions), do: {:ok, decisions}

    def handle_call({:get, decision_id}, _from, decisions) do
      case Enum.find(decisions, &(&1.decision_id == decision_id)) do
        nil -> {:reply, {:error, :not_found}, decisions}
        decision -> {:reply, {:ok, decision}, decisions}
      end
    end

    def handle_call({:retained_lookup, decision_id}, _from, decisions) do
      decision = Enum.find(decisions, &(&1.decision_id == decision_id))
      {:reply, {:ok, %{decision: decision, health: :writable}}, decisions}
    end

    def handle_call({:retained_query, query}, _from, decisions) do
      current = Map.new(decisions, &{&1.decision_id, &1})
      index = RetainedSnapshot.build_index(current)

      {:reply, RetainedSnapshot.query(current, index, :writable, query), decisions}
    end

    def handle_call(:retained_counts, _from, decisions) do
      current = Map.new(decisions, &{&1.decision_id, &1})
      index = RetainedSnapshot.build_index(current)
      {:reply, RetainedSnapshot.counts(index, :writable), decisions}
    end

    def handle_call(:list, _from, decisions), do: {:reply, decisions, decisions}
    def handle_call(:health, _from, decisions), do: {:reply, :writable, decisions}
    def handle_call({:recent_decisions, limit}, _from, decisions), do: {:reply, Enum.take(decisions, limit), decisions}

    def handle_call({:recent_audit_history, _limit}, _from, decisions) do
      {:reply, %{records: [], contexts: %{}, revisions: %{}}, decisions}
    end

    def handle_call(:all_audit_history, _from, decisions), do: {:reply, %{}, decisions}
  end

  defmodule StaticPayloadProvider do
    use GenServer

    def start_link(responses), do: GenServer.start_link(__MODULE__, Map.new(responses))
    def init(responses), do: {:ok, responses}

    def handle_call(request, _from, responses) do
      {:reply, Map.fetch!(responses, request), responses}
    end
  end

  setup do
    linear_client_module = Application.get_env(:aiur, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:aiur, :linear_client_module)
      else
        Application.put_env(:aiur, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:aiur, AiurWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:aiur, AiurWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "dashboard decision routes render a stable deep link from the real Decision projection" do
    orchestrator_name = Module.concat(__MODULE__, :DecisionRouteOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :DecisionRouteStore)
    snapshot = static_snapshot()
    decision = decision_fixture("decision-live-route")

    unrelated =
      Enum.map(1..50, fn index ->
        decision_fixture("unrelated-decision-#{index}")
        |> Map.put(:blocking, false)
        |> Map.put(:urgency, :low)
      end)

    orchestrator = start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot})

    decision_store =
      start_supervised!({StaticDecisionStore, name: decision_store_name, decisions: [decision | unrelated]})

    cache = start_supervised!({AiurWeb.ControlCenterCache, name: nil})

    decision_metrics =
      start_static_payload_provider(:decision_route_metrics, snapshots: %{})

    recent_merges =
      start_static_payload_provider(
        :decision_route_recent_merges,
        snapshot: %{
          merges: [],
          health: :writable,
          reconciliation: %{status: :complete, partial?: false, pages_fetched: 0}
        }
      )

    start_test_endpoint(
      orchestrator: orchestrator,
      snapshot_timeout_ms: 50,
      decision_store: decision_store,
      decision_metrics: decision_metrics,
      recent_merge_store: recent_merges,
      control_center_cache: cache,
      dashboard_writable: false
    )

    providers = %{
      orchestrator: orchestrator,
      decision_store: decision_store,
      decision_metrics: decision_metrics,
      recent_merge_store: recent_merges,
      control_center_cache: cache
    }

    {:ok, inbox_view, inbox_html} = live(build_conn(), "/commands")
    assert inbox_html =~ "Commands inbox"

    assert has_element?(inbox_view, ~s(a[href="/commands/decision-live-route"])),
           dashboard_route_diagnostic(inbox_html, providers)

    refute has_element?(inbox_view, ~s(a[href="/commands/unrelated-decision-50"]))

    {:ok, detail_view, detail_html} = live(build_conn(), "/commands/decision-live-route")

    assert has_element?(detail_view, "#decision-detail-decision-live-route"),
           dashboard_route_diagnostic(detail_html, providers)

    assert detail_html =~ "Should this real projected decision ship?"
    assert detail_html =~ "&lt;script&gt;never execute&lt;/script&gt;"
    assert detail_html =~ "Read-only mode · Command mutation controls are hidden."
    refute detail_html =~ "phx-click=\"answer-decision\""

    {:ok, _missing_view, missing_html} = live(build_conn(), "/commands/not-present")
    assert missing_html =~ "Command not found"
    assert missing_html =~ "not-present"

    lifecycle_diagnostic = dashboard_route_diagnostic(missing_html, providers)
    assert Process.alive?(decision_store), lifecycle_diagnostic
    assert GenServer.whereis(decision_store_name) == decision_store, lifecycle_diagnostic
  end

  defp start_static_payload_provider(id, responses) do
    {StaticPayloadProvider, responses}
    |> Supervisor.child_spec(id: {StaticPayloadProvider, id})
    |> start_supervised!()
  end

  defp dashboard_route_diagnostic(html, providers) do
    payload =
      AiurWeb.ControlCenterPresenter.state_payload(providers.orchestrator, 50,
        decision_store: providers.decision_store,
        decision_metrics: providers.decision_metrics,
        recent_merge_store: providers.recent_merge_store
      )

    provider_status =
      Map.new(providers, fn {name, server} ->
        pid = GenServer.whereis(server)
        {name, %{server: inspect(server), pid: inspect(pid), alive?: is_pid(pid) and Process.alive?(pid)}}
      end)

    """
    Expected the stable Decision route from isolated providers.
    provider_status=#{inspect(provider_status, pretty: true)}
    payload_health=#{inspect(payload.provider_health, pretty: true)}
    payload_decision_ids=#{inspect(Enum.map(payload.decisions, & &1.decision_id))}
    rendered_html=#{html}
    """
  end

  defp decision_fixture(decision_id) do
    %Aiur.Decision{
      decision_id: decision_id,
      source_id: decision_id,
      version: 1,
      ticket: %{identifier: "MT-HTTP", title: "Projected ticket", url: "https://example.test/issues/MT-HTTP"},
      source: %{agent_id: "agent-http", session_id: "thread-http", event_id: "event-http"},
      kind: "architecture",
      authority: :human_required,
      urgency: :critical,
      blocking: true,
      reversibility: :reversible,
      question: "Should this real projected decision ship?",
      context: %{short_summary: "A durable request", long_context_markdown: "<script>never execute</script>"},
      options: [],
      recommendation: nil,
      consequence_of_delay: "The ticket agent remains paused.",
      artifacts: [],
      created_at: ~U[2026-07-12 12:00:00Z],
      source_created_at: ~U[2026-07-12 12:00:00Z],
      content_hash: "hash-#{decision_id}"
    }
  end
end
