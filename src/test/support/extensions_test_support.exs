defmodule Aiur.ExtensionsTestSupport do
  import ExUnit.Assertions
  import ExUnit.Callbacks
  alias Aiur.Orchestrator.SnapshotStore

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts) do
      :ok = SnapshotStore.publish(Keyword.fetch!(opts, :name), Keyword.fetch!(opts, :snapshot))
      {:ok, opts}
    end

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end

    def handle_call({:send_operator_message, issue_identifier, _payload}, _from, state) do
      reply =
        Keyword.get(state, :send_operator_message, {:ok, 1})
        |> case do
          fun when is_function(fun, 1) -> fun.(issue_identifier)
          other -> other
        end

      {:reply, reply, state}
    end

    def handle_call({:lookup_operator_message, _lookup}, _from, state) do
      {:reply, Keyword.get(state, :lookup_operator_message, {:error, :unknown_message}), state}
    end

    def handle_call({:lookup_operator_message, _lookup, _expected}, _from, state) do
      {:reply, Keyword.get(state, :lookup_operator_message, {:error, :unknown_message}), state}
    end
  end

  def start_test_endpoint(overrides) do
    control_center_cache =
      Keyword.get_lazy(overrides, :control_center_cache, fn ->
        start_supervised!({AiurWeb.ControlCenterCache, name: nil})
      end)

    endpoint_config =
      :aiur
      |> Application.get_env(AiurWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: true,
        dashboard_auth_required: false,
        control_center_cache: control_center_cache
      )
      |> Keyword.merge(overrides)

    Application.put_env(:aiur, AiurWeb.Endpoint, endpoint_config)
    Aiur.TestSupport.start_owned_endpoint!()
  end

  def static_snapshot(opts \\ []) do
    workspace_path = Keyword.get(opts, :workspace_path)

    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          workspace_path: workspace_path,
          queue_depth: 1,
          control: %{
            accepts_operator_messages: true,
            can_interrupt: false,
            accepted_delivery_policies: [:checkpoint],
            safe_checkpoints: [:notification, :tool_result],
            queue_depth: 1
          },
          agent_input_tokens: 4,
          agent_output_tokens: 8,
          agent_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      idle: [],
      agent_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      polling: %{
        checking?: false,
        effective_interval_ms: 600_000,
        idle_backoff: %{active?: true, factor: 5.0},
        next_poll_in_ms: 480_000,
        poll_interval_ms: 120_000
      },
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  def with_static_units(snapshot) do
    observed_at = DateTime.utc_now()
    running_identity = static_units_identity("1100")
    retrying_identity = static_units_identity("1101")

    snapshot =
      snapshot
      |> update_in([:running], fn rows ->
        Enum.map(rows, &Map.merge(&1, %{identifier: "1100", tracker_identity: running_identity}))
      end)
      |> update_in([:retrying], fn rows ->
        Enum.map(rows, &Map.merge(&1, %{identifier: "1101", tracker_identity: retrying_identity}))
      end)

    membership = %{
      run_id: "extensions-dashboard",
      generation: 1,
      health: :healthy,
      health_message: nil,
      freshness: %{status: :fresh, observed_at: observed_at},
      members: [
        static_units_member(running_identity, :running, observed_at),
        static_units_member(retrying_identity, :retrying, observed_at)
      ],
      truncated?: false
    }

    {snapshot, membership}
  end

  def static_units_identity(identifier) do
    %Aiur.TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: Aiur.TestSupport.github_owner(),
      repository: Aiur.TestSupport.github_repository_name(),
      provider_id: "NODE-#{identifier}",
      identifier: identifier,
      reason: nil
    }
  end

  defp static_units_member(identity, lifecycle, observed_at) do
    %{
      identity: identity,
      lifecycle: lifecycle,
      terminal?: false,
      first_observed_at: observed_at,
      last_observed_at: observed_at
    }
  end

  def static_units_activity do
    %{
      generation: 1,
      health: :healthy,
      freshness: %{status: :fresh},
      entries: []
    }
  end

  def assert_occ_sections(payload) do
    assert %{"entries" => decision_entries, "status" => decision_status} = payload["decision_history"]
    assert is_list(decision_entries)
    assert decision_status in ["available", "unavailable"]

    assert %{
             "entries" => merge_entries,
             "reconciliation" => %{"pages_fetched" => pages_fetched},
             "status" => merge_status
           } = payload["recent_merges"]

    assert is_list(merge_entries)
    assert is_integer(pages_fetched)
    assert merge_status in ["available", "degraded", "unavailable"]

    assert %{"available?" => available?, "message" => message} = payload["analytics"]
    assert is_boolean(available?)
    assert is_binary(message)
  end

  def without_occ_sections(payload) do
    Map.drop(payload, ~w(decision_history recent_merges analytics capacity capacity_hold dispatch_hold daemon_started_at observations snapshot_freshness))
  end

  # Dashboard routes are behind the FinancialDataAccess plug, which challenges
  # any request once credentials are configured (regardless of `dashboard_auth_required`).
  # test_helper configures credentials globally, so every extension-test request to a
  # dashboard route must present them. Tests that exercise the missing-configuration
  # path build an unauthenticated conn explicitly.
  def build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header(
      "authorization",
      "Basic " <> Base.encode64("operator:test-dashboard-secret")
    )
  end

  def assert_eventually(fun, attempts \\ 20)

  def assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  def assert_eventually(_fun, 0), do: flunk("condition not met in time")
end
