defmodule AiurWeb.GatewayLiveTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Endpoint
  @endpoint Endpoint

  def build_conn do
    Phoenix.ConnTest.build_conn() |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
  end

  setup do
    config = Application.get_env(:aiur, Endpoint)
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "test-dashboard-secret")

    Application.put_env(
      :aiur,
      Endpoint,
      EndpointStubs.scope(
        Keyword.merge(config || [],
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

    path = Path.join(System.tmp_dir!(), "gateway-live-registry-#{System.unique_integer([:positive])}.yaml")
    File.write!(path, "version: 1\ninstances:\n  nook:\n    url: https://nook.test\n    gateway_id: NOOK\n    label: Nook\n")
    previous = Application.get_env(:aiur, :projects_home_registry)
    Application.put_env(:aiur, :projects_home_registry, path)

    on_exit(fn ->
      Application.put_env(:aiur, Endpoint, config)
      Aiur.TestSupport.restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      Aiur.TestSupport.restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
      if previous, do: Application.put_env(:aiur, :projects_home_registry, previous), else: Application.delete_env(:aiur, :projects_home_registry)
      Aiur.TestCleanup.rm_rf!(path)
    end)

    :ok
  end

  test "an unknown gateway name says so and links back" do
    {:ok, _view, html} = live(build_conn(), "/gateways?gateway=nope")
    assert html =~ "unknown gateway"
    assert html =~ ~s(href="/gateways")
    refute html =~ "data-gateway-card"
  end

  test "this gateway shows connectivity and workload as two separate elements" do
    {:ok, view, _html} = live(build_conn(), "/gateways")
    assert has_element?(view, ~s([data-gateway-card="local"] [data-field="connectivity"]), "online")
    assert has_element?(view, ~s([data-gateway-card="local"] [data-field="workload"]))
    assert has_element?(view, ~s([data-action="pause-all"]))
    assert render(view) =~ ~s(data-peers=)
  end

  test "selecting a peer hides pause all and the local card" do
    {:ok, view, _html} = live(build_conn(), "/gateways?gateway=nook")
    refute has_element?(view, ~s([data-action="pause-all"]))
    refute has_element?(view, ~s([data-gateway-card="local"]))
    assert has_element?(view, ~s(#gateway-peers[data-selected="nook"]))
  end

  test "the home screen links each peer to its gateway view" do
    {:ok, view, _html} = live(build_conn(), "/projects")
    assert has_element?(view, ~s(a[data-gateway-filter-link="nook"][href="/gateways?gateway=nook"]), "Nook")
  end
end
