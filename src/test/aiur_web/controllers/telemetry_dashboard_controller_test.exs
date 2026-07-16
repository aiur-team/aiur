defmodule AiurWeb.TelemetryDashboardControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AiurWeb.Router

  @fixture Path.expand("../../fixtures/run_telemetry/session-a/telemetry.ndjson", __DIR__)

  setup do
    original_log_file = Application.get_env(:aiur, :log_file)
    original_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    original_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    root = Path.join(System.tmp_dir!(), "aiur-telemetry-route-#{System.unique_integer([:positive])}")
    telemetry_path = Path.join(root, "telemetry.ndjson")

    File.mkdir_p!(root)
    File.cp!(@fixture, telemetry_path)
    Application.put_env(:aiur, :log_file, Path.join(root, "aiur.log"))
    System.delete_env("AIUR_DASHBOARD_USERNAME")
    System.delete_env("AIUR_DASHBOARD_PASSWORD")

    on_exit(fn ->
      restore_application_env(:log_file, original_log_file)
      restore_env("AIUR_DASHBOARD_USERNAME", original_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", original_password)
      File.rm_rf!(root)
    end)

    %{telemetry_path: telemetry_path}
  end

  test "renders the canonical self-contained report with secure non-cacheable headers" do
    conn = Router.call(conn(:get, "/analytics?path=/etc/passwd"), Router.init([]))

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["no-store, max-age=0"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
    assert get_resp_header(conn, "content-security-policy") == ["base-uri 'self'; frame-ancestors 'self';"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    assert {:ok, document} = Floki.parse_document(conn.resp_body)
    assert Floki.find(document, "script#aiur-data[type='application/json']") != []
    assert Floki.find(document, "#ticket-lifecycle") != []
    assert conn.resp_body =~ "Compare daemon, Executor, and ticket process trees"
    assert conn.resp_body =~ ~s(actor === "_operator" ? "Executor" : actor)
    assert conn.resp_body =~ ~s(operator_process_unavailable: "Executor process unavailable")
    assert conn.resp_body =~ ~s(operator_pid_unavailable: "Executor PID unavailable")
    refute conn.resp_body =~ "/etc/passwd"
  end

  test "the analytics route is covered by dashboard basic auth" do
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")

    unauthorized = Router.call(conn(:get, "/analytics"), Router.init([]))
    assert unauthorized.status == 401

    authorized =
      :get
      |> conn("/analytics")
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
      |> Router.call(Router.init([]))

    assert authorized.status == 200
  end

  test "returns an explicit no-store unavailable state when telemetry is absent", %{telemetry_path: path} do
    File.rm!(path)
    conn = Router.call(conn(:get, "/analytics"), Router.init([]))

    assert conn.status == 404
    assert conn.resp_body =~ "require a debug telemetry run"
    assert get_resp_header(conn, "cache-control") == ["no-store, max-age=0"]
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
