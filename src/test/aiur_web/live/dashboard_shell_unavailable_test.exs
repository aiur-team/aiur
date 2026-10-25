defmodule AiurWeb.DashboardShellUnavailableTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias AiurWeb.Endpoint

  @endpoint Endpoint

  test "Analytics with an unreadable Command store omits the attention dot and renders a notice" do
    previous = Application.fetch_env(:aiur, Endpoint)

    config =
      Keyword.merge(Application.get_env(:aiur, Endpoint, []),
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_auth_required: false,
        dashboard_writable: false,
        decision_store: __MODULE__.MissingDecisionStore,
        orchestrator: __MODULE__.MissingOrchestrator
      )

    Application.put_env(:aiur, Endpoint, config)
    on_exit(fn -> Aiur.TestSupport.restore_app_env([{Endpoint, previous}]) end)
    Aiur.TestSupport.start_owned_endpoint!()

    {:ok, _view, html} = live(build_conn() |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret")), "/analytics")
    doc = Floki.parse_document!(html)
    assert length(Floki.find(doc, "a[href='/commands']")) == 1
    assert Floki.find(doc, "a[href='/commands'] .snav-c") == []
    assert Floki.find(doc, ".readonly-banner") |> Floki.text() =~ "Command counts unavailable"
    assert Floki.find(doc, "#decisions-banner") == []
  end
end
