defmodule AiurWeb.ProjectScopeTest do
  # #7865: in projects mode the dashboard must reach a project's Orchestrator, not the unregistered bare name.
  use Aiur.TestSupport

  import ExUnit.CaptureLog
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, recycle: 1]
  import Phoenix.LiveViewTest
  import Plug.Conn
  import Plug.Test

  alias Aiur.Project
  alias Aiur.Project.{Context, Supervisors, Table, Watcher}
  alias Aiur.TestSupport.WorkflowFiles
  alias AiurWeb.PresenterFixtures

  @endpoint AiurWeb.Endpoint

  setup do
    root = Aiur.TestSupport.tmp_root!("project-scope")
    previous_endpoint = Application.get_env(:aiur, AiurWeb.Endpoint)

    on_exit(fn ->
      if previous_endpoint, do: Application.put_env(:aiur, AiurWeb.Endpoint, previous_endpoint), else: Application.delete_env(:aiur, AiurWeb.Endpoint)
      Enum.each(["o/a", "o/b"], &Table.drop/1)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    start_supervised!(Supervisors)
    start_supervised!({Watcher, alert_fun: fn _name, _opts -> :ok end})
    {:ok, root: root}
  end

  test "a snapshot request for project B returns B's orchestrator snapshot", %{root: root} do
    start_publishing(project("o/a", root, 3))
    start_publishing(project("o/b", root, 5))

    with_http_server(fn ->
      assert %{"capacity" => %{"configured" => 5}} = await_snapshot("/api/v1/state?project=o/b")
      assert %{"capacity" => %{"configured" => 3}} = await_snapshot("/api/v1/state?project=O/A")

      conn = request("/api/v1/state")
      assert conn.status == 409
      assert %{"error" => %{"code" => "project_required"}, "projects" => ["o/a", "o/b"]} = Jason.decode!(conn.resp_body)
    end)
  end

  test "an unknown pick is a 404 naming it; every orchestrator handler asks for a pick", %{root: root} do
    start_publishing(project("o/a", root, 3))
    start_publishing(project("o/b", root, 5))

    with_http_server(fn ->
      conn = request("/api/v1/state?project=o/zzz")
      assert conn.status == 404
      assert %{"error" => %{"code" => "unknown_project"}, "project" => "o/zzz", "projects" => ["o/a", "o/b"]} = Jason.decode!(conn.resp_body)

      for {method, path} <- [{:get, "/api/v1/ENG-1"}, {:post, "/api/v1/refresh"}, {:post, "/api/v1/ENG-1/pause"}, {:post, "/api/v1/ENG-1/cancel"}] do
        conn = request(path, method)
        assert {conn.status, Jason.decode!(conn.resp_body)["error"]["code"]} == {409, "project_required"}, "#{method} #{path}"
      end
    end)
  end

  test "the session remembers a pick for the rest of the visit", %{root: root} do
    start_publishing(project("o/a", root, 3))
    start_publishing(project("o/b", root, 5))

    with_http_server(fn ->
      assert %{"capacity" => %{"configured" => 5}} = await_snapshot("/api/v1/state?project=o/b")
      picked = request("/api/v1/state?project=o/b")
      assert %{"capacity" => %{"configured" => 5}} = picked |> request_after("/api/v1/state") |> json_body()
    end)
  end

  test "with several projects and no pick, project pages send the visitor to pick one", %{root: root} do
    start_publishing(project("o/a", root, 3))
    start_publishing(project("o/b", root, 5))

    with_http_server(fn ->
      assert {:error, {:redirect, %{to: "/projects?pick=required"}}} = live(browser_conn(), "/build")
      assert {:error, {:redirect, %{to: "/projects?pick=unknown&unknown=o%2Fzzz"}}} = live(browser_conn(), "/build?project=o/zzz")
    end)
  end

  test "with one project the dashboard needs no selection", %{root: root} do
    a = project("o/a", root, 3)
    start_publishing(a)

    with_http_server(fn ->
      assert %{"capacity" => %{"configured" => 3}} = await_snapshot("/api/v1/state")
    end)
  end

  test "with one project the build home reads that project's index and daemon", %{root: root} do
    start_publishing(project("o/a", root, 3))

    with_http_server(fn ->
      {:ok, view, _html} = live(browser_conn(), "/build")
      assert %{build_state: :ready, build_snapshot: snapshot} = await_build(view)
      assert snapshot["daemon"]["state"] not in ["offline", "unknown"]
    end)
  end

  defp project(repo, root, max_agents) do
    state_root = Path.join(root, String.replace(repo, "/", "-"))
    config = Path.join([state_root, "repo", ".aiur", "config"])
    File.mkdir_p!(Path.dirname(config))
    WorkflowFiles.write_workflow_file!(config, tracker_kind: "memory", max_concurrent_agents: max_agents)
    Project.from_machine_entry(%{repo: repo, config: config}, state_root)
  end

  # Tests turn the initial poll off, so publish each project's first snapshot from inside its tree.
  defp start_publishing(%Project{} = project) do
    {:ok, _} = Supervisors.start_project(project)

    Task.async(fn ->
      Context.put(project)
      Aiur.Orchestrator.server() |> GenServer.whereis() |> PresenterFixtures.publish_dashboard_snapshot()
    end)
    |> Task.await()
  end

  defp with_http_server(fun) do
    capture_log(fn ->
      {:ok, pid} = Aiur.HttpServer.start_link(host: "127.0.0.1", port: 0, dashboard_writable: true)

      try do
        fun.()
      after
        Supervisor.stop(pid)
      end
    end)
  end

  defp request(path, method \\ :get) do
    method
    |> conn(path)
    |> put_req_header("origin", "http://localhost")
    |> put_req_header("x-aiur-request", "1")
    |> put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
    |> AiurWeb.Endpoint.call(AiurWeb.Endpoint.init([]))
  end

  defp request_after(previous, path) do
    previous
    |> recycle()
    |> put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
    |> get(path)
  end

  defp await_build(view, attempts \\ 100) do
    assigns = :sys.get_state(view.pid).socket.assigns

    cond do
      assigns.build_state != :loading -> assigns
      attempts == 0 -> flunk("build home never left :loading")
      true -> Process.sleep(50) && await_build(view, attempts - 1)
    end
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp browser_conn do
    build_conn() |> put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
  end

  # A fresh orchestrator publishes its first snapshot asynchronously.
  defp await_snapshot(path, attempts \\ 100) do
    conn = request(path)
    payload = Jason.decode!(conn.resp_body)

    cond do
      conn.status == 200 and not Map.has_key?(payload, "error") ->
        payload

      attempts == 0 ->
        flunk("no snapshot for #{path}: #{conn.status} #{conn.resp_body}")

      true ->
        Process.sleep(50)
        await_snapshot(path, attempts - 1)
    end
  end
end
