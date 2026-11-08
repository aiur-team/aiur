defmodule AiurWeb.ProjectsHomeLiveTest do
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
    previous = Map.new([:gateway_summary_metadata, Endpoint], &{&1, Application.get_env(:aiur, &1)})
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "test-dashboard-secret")

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
    path = Aiur.Workflow.workflow_file_path()
    original = File.read!(path)

    on_exit(fn ->
      for {key, value} <- previous, do: restore_app_env(key, value)
      File.write!(path, original)
      Aiur.WorkflowStore.force_reload(15_000)
      Aiur.TestSupport.restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      Aiur.TestSupport.restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    {:ok, workflow_path: path}
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)

  defp projects_home!(path, on?) do
    base = path |> File.read!() |> String.replace(~r/^dashboard:\n  projects_home: .*\n/m, "")
    Aiur.TestSupport.write_workflow_file_atomic!(path, "dashboard:\n  projects_home: #{on?}\n" <> base)
    :ok = Aiur.WorkflowStore.force_reload(15_000)
  end

  test "a bare / goes to /projects only with the flag on", %{workflow_path: path} do
    projects_home!(path, true)
    assert {:error, {:live_redirect, %{to: "/projects"}}} = live(build_conn(), "/")
    assert {:ok, _view, html} = live(build_conn(), "/build")
    refute html =~ ~s(id="projects-home")
    assert {:ok, _view, _html} = live(build_conn(), "/?view=list")

    projects_home!(path, false)
    assert {:ok, _view, html} = live(build_conn(), "/")
    refute html =~ ~s(id="projects-home")
  end

  test "renders local rows with a Build link; an unreadable count is unknown, not zero", %{workflow_path: path} do
    projects_home!(path, true)

    Application.put_env(:aiur, :gateway_summary_metadata, fn ->
      %{"data" => %{"gateway_label" => "PC", "agent_count" => 3, "agent_capacity" => 12, "projects" => [%{"repo" => "a/b", "running" => 3}, %{"repo" => "c/d", "running" => nil}]}}
    end)

    {:ok, _view, html} = live(build_conn(), "/projects")
    assert html =~ "3 of 12 agents"
    assert html =~ ~r/data-project-row="a\/b"[^>]*>\s*a\/b · running 3 · ready unknown/
    assert html =~ ~r/c\/d · running unknown/
    assert html =~ ~s(href="/build")
  end

  test "a summary that cannot be read renders unknown, never 0 agents", %{workflow_path: path} do
    projects_home!(path, true)
    Application.put_env(:aiur, :gateway_summary_metadata, fn -> raise "boom" end)
    {:ok, _view, html} = live(build_conn(), "/projects")
    assert html =~ "unknown of unknown agents"
    refute html =~ "0 agents"
  end
end
