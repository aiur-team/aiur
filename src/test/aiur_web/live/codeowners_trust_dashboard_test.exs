defmodule AiurWeb.CodeownersTrustDashboardTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.GitHub.CodeOwners
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.ControlCenterCache

  @endpoint AiurWeb.Endpoint
  @moduletag :tmp_dir

  test "dashboard reads degraded trust with age and clears it after recovery", %{tmp_dir: root} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    path = Path.join(root, "CODEOWNERS")
    File.write!(path, "* @acme/team\n")
    previous = Process.whereis(CodeOwners)
    if previous, do: Process.unregister(CodeOwners)
    # The CodeOwners server resolves teams with the configured token.
    token_key = {Aiur.GitHub.Access.Token, :resolved_token}
    previous_token = :persistent_term.get(token_key, :unset)
    :persistent_term.put(token_key, "test-gh-token")
    on_exit(fn -> if previous_token == :unset, do: :persistent_term.erase(token_key), else: :persistent_term.put(token_key, previous_token) end)

    on_exit(fn ->
      if previous && Process.alive?(previous), do: Process.register(previous, CodeOwners)
    end)

    server =
      start_supervised!({CodeOwners, path: path, request_fun: fn _ -> {:ok, %{status: 503, body: %{}}} end, alert_fun: fn _, _, _ -> :ok end, refresh_seconds: 86_400})

    assert CodeOwners.trust_snapshot(server).degradation.cause ==
             {:team_lookup_failed, "@acme/team", {:github, :http, %{status: 503}}}

    start_endpoint()

    conn = build_conn() |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
    {:ok, view, _html} = live(conn, "/")
    banner = element(view, "#codeowners-trust-degraded")
    html = render(banner)
    assert html =~ "Team lookup failed for @acme/team"
    assert html =~ "503"
    assert html =~ ~r/age \d+s/
    File.write!(path, "* @direct\n")
    CodeOwners.refresh(server)
    send(view.pid, :runtime_tick)
    refute has_element?(view, "#codeowners-trust-degraded")
  end

  defp start_endpoint do
    previous = Application.get_env(:aiur, AiurWeb.Endpoint)
    cache = start_supervised!({ControlCenterCache, name: nil})

    config =
      Keyword.merge(previous || [],
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false,
        control_center_cache: cache
      )

    Application.put_env(:aiur, AiurWeb.Endpoint, EndpointStubs.scope(config))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, AiurWeb.Endpoint, previous), else: Application.delete_env(:aiur, AiurWeb.Endpoint)
    end)

    Aiur.TestSupport.start_owned_endpoint!()
  end
end
