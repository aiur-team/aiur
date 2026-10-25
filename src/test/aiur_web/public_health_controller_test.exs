defmodule AiurWeb.PublicHealthControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test

  setup do
    previous = Application.get_env(:aiur, :health_ready_fun)
    previous_orchestrator = Application.get_env(:aiur, :health_orchestrator_pid_fun)
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    System.delete_env("AIUR_DASHBOARD_USERNAME")
    System.delete_env("AIUR_DASHBOARD_PASSWORD")

    on_exit(fn ->
      if is_nil(previous), do: Application.delete_env(:aiur, :health_ready_fun), else: Application.put_env(:aiur, :health_ready_fun, previous)
      if is_nil(previous_orchestrator), do: Application.delete_env(:aiur, :health_orchestrator_pid_fun), else: Application.put_env(:aiur, :health_orchestrator_pid_fun, previous_orchestrator)
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    :ok
  end

  test "health is public and reports process liveness" do
    conn = request(:get, "/healthz")
    assert conn.status == 200
    assert conn.resp_body == "ok\n"
  end

  test "readiness is unavailable before boot and ready after tracker preflight" do
    Application.put_env(:aiur, :health_ready_fun, fn -> {:error, :not_booted} end)
    assert request(:get, "/readyz").status == 503

    Application.put_env(:aiur, :health_ready_fun, fn -> :ok end)
    ready = request(:get, "/readyz")
    assert ready.status == 200
    assert ready.resp_body == "ready\n"
  end

  test "readiness is unavailable when the orchestrator has not booted" do
    Application.delete_env(:aiur, :health_ready_fun)
    Application.put_env(:aiur, :health_orchestrator_pid_fun, fn -> nil end)

    assert request(:get, "/readyz").status == 503
  end

  defp request(method, path), do: AiurWeb.Endpoint.call(conn(method, path), AiurWeb.Endpoint.init([]))

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
