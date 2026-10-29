defmodule AiurWeb.DashboardJoinBudgetTest do
  @moduledoc """
  The connected LiveView join must stay under one second even when the
  dashboard's provider reads are slow, as they are on a busy live daemon
  (#5163). Until the join finishes, the page is the static first render and
  form submits are dropped.
  """

  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Aiur.OpenTicketSource.Snapshot, as: OpenTicketSnapshot
  alias Aiur.TestSupport.EndpointStubs
  alias Aiur.TrackerIdentity
  alias AiurWeb.ControlCenterCache

  @endpoint AiurWeb.Endpoint
  @join_budget_ms 1_000
  # A busy daemon: the ticket read answers slowly, and the other provider reads
  # stall until the load budget cuts each of them off.
  @slow_read_ms 600
  @stalled_read_ms 5_000
  @ticket_count 300

  setup do
    test = self()
    previous = Application.get_env(:aiur, AiurWeb.Endpoint)
    cache = start_supervised!({ControlCenterCache, name: nil})
    snapshot = open_ticket_snapshot(@ticket_count)

    config =
      (previous || [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: true,
        dashboard_auth_required: false,
        control_center_cache: cache,
        open_tickets_fun: fn ->
          Process.sleep(@slow_read_ms)
          snapshot
        end,
        units_fleet_fun: &stalled_read/0,
        units_membership_fun: &stalled_read/0,
        units_activity_fun: &stalled_read/0,
        # Record the post-join refresh instead of running it.
        control_center_reload_timer: fn pid, message, _delay_ms ->
          send(test, {:reload_scheduled, pid, message})
          make_ref()
        end
      )
      |> EndpointStubs.scope()

    Application.put_env(:aiur, AiurWeb.Endpoint, config)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:aiur, AiurWeb.Endpoint)
        kept -> Application.put_env(:aiur, AiurWeb.Endpoint, kept)
      end
    end)

    Aiur.TestSupport.start_owned_endpoint!()
    :ok
  end

  for {path, marker} <- [{"/commands", "control-panel"}, {"/units", "usage-watch"}] do
    @tag timeout: 30_000
    test "#{path} joins within budget when provider reads are slow" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
        |> get(unquote(path))

      assert html_response(conn, 200) =~ "data-phx-main"

      started = System.monotonic_time(:millisecond)
      {:ok, view, _html} = live(conn)
      join_ms = System.monotonic_time(:millisecond) - started

      assert join_ms < @join_budget_ms, "#{unquote(path)} join took #{join_ms} ms"
      assert render(view) =~ unquote(marker)
      # The join served the cached payload, so it must refresh it right after.
      view_pid = view.pid
      assert_receive {:reload_scheduled, ^view_pid, :reload_payload}, 1_000
    end
  end

  defp stalled_read, do: Process.sleep(@stalled_read_ms)

  defp open_ticket_snapshot(count) do
    %OpenTicketSnapshot{
      status: :available,
      generation: 1,
      observed_at: ~U[2026-10-18 12:00:00Z],
      tickets: Enum.map(1..count, &open_ticket(Integer.to_string(&1 + 1000)))
    }
  end

  defp open_ticket(identifier) do
    %{
      identity: %TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "its-everdred",
        repository: "aiur",
        provider_id: "NODE-#{identifier}",
        database_id: String.to_integer(identifier),
        identifier: identifier,
        reason: nil
      },
      identifier: identifier,
      title: "Backlog ticket #{identifier}",
      body_excerpt: nil,
      url: "https://github.com/its-everdred/aiur/issues/#{identifier}",
      state: "Todo",
      labels: ["complexity:3"],
      assignee: nil,
      created_at: ~U[2026-10-16 12:00:00Z],
      updated_at: ~U[2026-10-17 11:00:00Z]
    }
  end
end
