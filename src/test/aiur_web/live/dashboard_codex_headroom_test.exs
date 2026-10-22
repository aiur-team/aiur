defmodule AiurWeb.DashboardCodexHeadroomTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.ModelAvailability
  alias AiurWeb.Endpoint

  @endpoint Endpoint

  test "the Units Models panel shows the Codex headroom that `aiur agents` reports, with its age" do
    assert :ok = ModelAvailability.observe("codex", %{hourly: %{used: 26, limit: 100}})

    previous = Application.fetch_env(:aiur, Endpoint)
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "codex-headroom-secret")

    config =
      Keyword.merge(Application.get_env(:aiur, Endpoint, []),
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_auth_required: true,
        dashboard_writable: false,
        orchestrator: __MODULE__.MissingOrchestrator
      )

    Application.put_env(:aiur, Endpoint, config)

    on_exit(fn ->
      Aiur.TestSupport.restore_app_env([{Endpoint, previous}])
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    Aiur.TestSupport.start_owned_endpoint!()

    conn = build_conn() |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:codex-headroom-secret"))
    {:ok, view, _html} = live(conn, "/units")

    codex = view |> render() |> Floki.parse_document!() |> Floki.find(".rs-models [data-provider='codex']") |> Floki.text()

    assert codex =~ ~r/74% left · \d+s old/
    refute codex =~ "unknown"
  end
end
