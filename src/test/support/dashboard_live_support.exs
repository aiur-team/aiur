defmodule AiurWeb.DashboardLiveSupport do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport.UnitFixtures, only: [open_ticket_snapshot: 1]

  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.{ControlCenterCache, ControlCenterPresenter, DashboardLive}
  alias AiurWeb.DashboardLiveSupport.OrchestratorStubs.CountingOrchestrator

  def render_payload(fleet_payload, opts \\ []) do
    payload =
      Keyword.get_lazy(opts, :payload, fn ->
        ControlCenterPresenter.state_payload(
          :unused,
          1,
          fleet_fun: fn -> fleet_payload end,
          decisions_fun: fn -> [] end
        )
      end)

    selected_decision_id = Keyword.get(opts, :selected_decision_id)
    selected_decision = Enum.find(payload.decisions, &(&1.decision_id == selected_decision_id))

    assigns = %{
      payload: payload,
      now: DateTime.utc_now(),
      time_zone: "Etc/UTC",
      # This helper renders DashboardLive directly, bypassing mount/3, so it has
      # to seed every assign mount/3 seeds — including the server-owned sidebar
      # collapse state the shell reads.
      nav_collapsed: false,
      agent_log_modal: nil,
      drafts: %{},
      chat_errors: %{},
      decision_actions: %{},
      global_pause_error: Keyword.get(opts, :global_pause_error),
      writable: Keyword.get(opts, :writable, false),
      live_action: Keyword.get(opts, :live_action, :index),
      decision_filter: :all,
      selected_decision_id: selected_decision_id,
      selected_decision: selected_decision,
      selected_decision_status: Keyword.get(opts, :selected_decision_status, if(selected_decision, do: :available, else: :not_found)),
      selected_decision_health: Keyword.get(opts, :selected_decision_health)
    }

    assigns
    |> DashboardLive.render()
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  def global_pause_fleet(globally_paused) do
    %{
      generated_at: "2026-07-26T12:00:00Z",
      counts: %{running: 0, retrying: 0, idle: 0},
      running: [],
      retrying: [],
      idle: [],
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil,
      globally_paused: globally_paused
    }
  end

  def history_row_count(view) do
    view |> render() |> Floki.parse_document!() |> Floki.find("#command-history-rows tr.history-row") |> length()
  end

  def reveal_more_tickets(view) do
    view |> element(~s(button[phx-click="show-more-tickets"])) |> render_click()
  end

  def ticket_row_count(html) do
    html |> Floki.parse_document!() |> Floki.find("#tickets-rows tr.tickets-row") |> length()
  end

  # The value of the `selected` option of one named select. Blank comes back as
  # `nil` so it compares against an absent routing value rather than `""`.
  def selected_option(html, name) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(~s(select[name="#{name}"] option[selected]))
    |> Floki.attribute("value")
    |> List.first()
    |> case do
      "" -> nil
      value -> value
    end
  end

  # Dashboard routes are behind the FinancialDataAccess plug, which challenges
  # any request once credentials are configured (regardless of `dashboard_auth_required`).
  # test_helper configures credentials globally, so every dashboard render test must
  # present them. Tests that deliberately exercise the unauthenticated or
  # missing-configuration path build their own conn via `Phoenix.ConnTest.build_conn/0`.
  def build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header(
      "authorization",
      "Basic " <> Base.encode64("operator:test-dashboard-secret")
    )
  end

  def start_test_endpoint(overrides) do
    previous = Application.get_env(:aiur, AiurWeb.Endpoint)
    cache = start_supervised!({ControlCenterCache, name: nil})

    endpoint_config =
      :aiur
      |> Application.get_env(AiurWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false,
        control_center_cache: cache,
        # Without a stub the Tickets panel reads the app-global OpenTicketSource, which other test modules feed (#4862).
        open_tickets_fun: fn -> open_ticket_snapshot([]) end
      )
      |> Keyword.merge(overrides)

    Application.put_env(:aiur, AiurWeb.Endpoint, EndpointStubs.scope(endpoint_config))

    on_exit(fn -> if previous, do: Application.put_env(:aiur, AiurWeb.Endpoint, previous), else: Application.delete_env(:aiur, AiurWeb.Endpoint) end)
    Aiur.TestSupport.start_owned_endpoint!()
  end

  def restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  def restore_application_env(key, value), do: Application.put_env(:aiur, key, value)

  def disable_dashboard_writes do
    endpoint_config = Application.fetch_env!(:aiur, AiurWeb.Endpoint)
    disabled_config = Keyword.put(endpoint_config, :dashboard_writable, false)
    Application.put_env(:aiur, AiurWeb.Endpoint, disabled_config)
    :ok = AiurWeb.Endpoint.config_change([{AiurWeb.Endpoint, disabled_config}], [])
  end

  def assert_bounded_reload_burst(views, messages, cache, orchestrator, expire? \\ true) do
    baseline_count = CountingOrchestrator.snapshot_count(orchestrator)
    expected_pids = views |> Enum.map(& &1.pid) |> MapSet.new()

    for view <- views, message <- messages do
      send(view.pid, message)
    end

    Enum.each(views, fn view -> :sys.get_state(view.pid) end)

    scheduled_pids =
      Enum.map(views, fn _view ->
        assert_receive {:payload_reload_scheduled, pid, :reload_payload, delay_ms}, 0
        assert delay_ms in 50..450
        pid
      end)

    assert MapSet.new(scheduled_pids) == expected_pids
    assert length(Enum.uniq(scheduled_pids)) == length(views)
    refute_receive {:payload_reload_scheduled, _pid, :reload_payload, _delay_ms}, 0

    if expire?, do: expire_cached_payloads(cache)
    Enum.each(views, &reload_view/1)

    assert CountingOrchestrator.snapshot_count(orchestrator) == baseline_count
  end

  def expire_cached_payloads(cache) do
    :sys.replace_state(cache, fn state ->
      entries = Map.new(state.entries, fn {key, entry} -> {key, %{entry | loaded_at_ms: entry.loaded_at_ms - 60_000}} end)
      %{state | entries: entries}
    end)
  end

  def eventually(fun, attempts \\ 30)

  def eventually(fun, attempts) when is_function(fun, 0) and attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  def eventually(_fun, 0), do: false

  def reload_view(view) do
    send(view.pid, :reload_payload)
    :sys.get_state(view.pid)
    render(view)
  end

  def drain_metrics_notifications do
    receive do
      :decision_metrics_changed -> drain_metrics_notifications()
    after
      0 -> :ok
    end
  end

  def drain_dashboard_payload_notifications(orchestrator) do
    receive do
      {:dashboard_payload_loaded, ^orchestrator, _count} ->
        drain_dashboard_payload_notifications(orchestrator)
    after
      0 -> :ok
    end
  end

  def payload_latency(payload, decision_id) do
    payload.decisions
    |> Enum.find(&(&1.decision_id == decision_id))
    |> get_in([:latency, :snapshot])
  end

  def touch_cached_payloads(cache) do
    loaded_at_ms = System.monotonic_time(:millisecond)

    :sys.replace_state(cache, fn state ->
      entries = Map.new(state.entries, fn {key, entry} -> {key, %{entry | loaded_at_ms: loaded_at_ms}} end)
      %{state | entries: entries}
    end)
  end

  def cached_payloads_fresh?(cache, max_age_ms) do
    now_ms = System.monotonic_time(:millisecond)

    :sys.get_state(cache).entries
    |> Map.values()
    |> Enum.all?(&(now_ms - &1.loaded_at_ms < max_age_ms))
  end
end
