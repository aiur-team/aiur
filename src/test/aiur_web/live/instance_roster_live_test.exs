defmodule AiurWeb.InstanceRosterLiveTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Endpoint

  @endpoint Endpoint

  def build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
  end

  setup do
    previous = Map.new([:instance_roster_fun, Endpoint], &{&1, Application.get_env(:aiur, &1)})
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "test-dashboard-secret")

    Application.put_env(:aiur, :instance_roster_fun, fn ->
      {:ok,
       %{
         observed_at: ~U[2026-10-24 12:00:00Z],
         age_ms: 0,
         instances: [
           %{
             instance_id: "home-a",
             state: :live,
             age_ms: 10_000,
             version: "1.2.3",
             host_kind: "home",
             public_url: "https://home.example",
             leader?: nil,
             agent_count: 2,
             agent_capacity: 4,
             held_tickets: ["acme/widgets#41"],
             agents: [%{"identifier" => "acme/widgets#41", "state" => "running"}]
           },
           %{
             instance_id: "container-b",
             state: :stale,
             age_ms: 90_000,
             version: "1.2.2",
             host_kind: "container",
             public_url: nil,
             leader?: nil,
             agent_count: nil,
             agent_capacity: nil,
             held_tickets: [],
             agents: [%{"identifier" => "acme/widgets#42", "state" => "paused"}]
           }
         ]
       }}
    end)

    Application.put_env(
      :aiur,
      Endpoint,
      EndpointStubs.scope(
        Keyword.merge(previous[Endpoint] || [],
          server: false,
          dashboard_auth_required: false,
          browser_basic_auth: true,
          basic_auth_username: nil,
          basic_auth_password: nil,
          secret_key_base: String.duplicate("s", 64)
        )
      )
    )

    Aiur.TestSupport.start_owned_endpoint!()

    on_exit(fn ->
      for {key, value} <- previous, do: restore(key, value)
      Aiur.TestSupport.restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      Aiur.TestSupport.restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    :ok
  end

  test "roster renders a live and an expired instance with age-aware stale state" do
    {:ok, view, html} = live(build_conn(), "/instances")
    assert html =~ "home-a"
    assert html =~ "https://home.example"
    assert html =~ "Leader: unknown; agents: 2 / 4"
    assert html =~ "Held tickets: acme/widgets#41"
    assert has_element?(view, ~s([data-agent-instance="home-a"][data-observation-age-ms="10000"]), "acme/widgets#41 — running — home-a")
    assert has_element?(view, "[data-instance-state=stale]", "container-b")
    assert has_element?(view, ~s([data-instance-state=stale][data-age-ms="90000"]))
    assert has_element?(view, "[data-instance-state=stale] h3", "(stale)")
    assert has_element?(view, "[data-instance-state=stale] p", "heartbeat 1 minutes ago")
    assert has_element?(view, "[data-instance-state=stale]", "Leader: unknown; agents: unknown / unknown")
    assert has_element?(view, ~s([data-agent-instance="container-b"][data-observation-age-ms="90000"]), "acme/widgets#42 — paused — container-b (observed 1 minutes ago)")
  end

  test "dashboard roster explains an unavailable shared store" do
    Application.put_env(:aiur, :instance_roster_fun, fn -> {:error, :offline} end)

    {:ok, view, _html} = live(build_conn(), "/instances")

    assert has_element?(view, "[data-empty-reason=lease_store_unavailable]", "Instance roster could not be read from the shared lease store.")
  end

  test "dashboard roster explains when the shared store is disabled" do
    Application.put_env(:aiur, :instance_roster_fun, fn -> :disabled end)

    {:ok, view, _html} = live(build_conn(), "/instances")

    assert has_element?(view, "[data-empty-reason=lease_store_disabled]", "Instance roster is unavailable because no shared lease store is configured.")
  end

  test "main dashboard agent list names each instance and observation age" do
    {:ok, view, _html} = live(build_conn(), "/units")

    assert has_element?(view, ~s(#instance-agent-list [data-agent-instance="home-a"][data-observation-age-ms="10000"]), "acme/widgets#41 — running — home-a (observed 10 seconds ago)")
    assert has_element?(view, ~s(#instance-agent-list [data-agent-instance="container-b"][data-observation-age-ms="90000"]), "acme/widgets#42 — paused — container-b (stale) (observed 1 minutes ago)")
  end

  test "main dashboard explains an unavailable shared store for the all-instance agent list" do
    Application.put_env(:aiur, :instance_roster_fun, fn -> {:error, :offline} end)

    {:ok, view, _html} = live(build_conn(), "/units")

    assert has_element?(
             view,
             "#instance-agent-list [data-empty-reason=lease_store_unavailable]",
             "Agent roster is unavailable because the shared lease store could not be read."
           )
  end

  defp restore(key, nil), do: Application.delete_env(:aiur, key)
  defp restore(key, value), do: Application.put_env(:aiur, key, value)
end
