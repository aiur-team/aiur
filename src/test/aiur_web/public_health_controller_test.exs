defmodule AiurWeb.PublicHealthControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test

  setup do
    endpoint_config = Application.get_env(:aiur, AiurWeb.Endpoint, [])
    endpoint_missing = make_ref()

    endpoint_runtime_config =
      if Process.whereis(AiurWeb.Endpoint) do
        AiurWeb.Endpoint.config(:allowed_hosts, endpoint_missing)
      else
        endpoint_missing
      end

    previous = Application.get_env(:aiur, :health_ready_fun)
    previous_orchestrator = Application.get_env(:aiur, :health_orchestrator_pid_fun)
    previous_preflight = Application.get_env(:aiur, :health_tracker_preflight_fun)
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    System.delete_env("AIUR_DASHBOARD_USERNAME")
    System.delete_env("AIUR_DASHBOARD_PASSWORD")

    test_endpoint_config =
      Keyword.merge(endpoint_config,
        server: false,
        secret_key_base: String.duplicate("s", 64),
        allowed_hosts: ["localhost", "127.0.0.1", "[::1]"]
      )

    Application.put_env(:aiur, AiurWeb.Endpoint, test_endpoint_config)
    Aiur.TestSupport.start_owned_endpoint!()
    Phoenix.Config.put(AiurWeb.Endpoint, :allowed_hosts, Keyword.fetch!(test_endpoint_config, :allowed_hosts))

    on_exit(fn ->
      Application.put_env(:aiur, AiurWeb.Endpoint, endpoint_config)

      if Process.whereis(AiurWeb.Endpoint) do
        if endpoint_runtime_config == endpoint_missing do
          :ets.delete(AiurWeb.Endpoint, :allowed_hosts)
        else
          Phoenix.Config.put(AiurWeb.Endpoint, :allowed_hosts, endpoint_runtime_config)
        end
      end

      if is_nil(previous), do: Application.delete_env(:aiur, :health_ready_fun), else: Application.put_env(:aiur, :health_ready_fun, previous)
      if is_nil(previous_orchestrator), do: Application.delete_env(:aiur, :health_orchestrator_pid_fun), else: Application.put_env(:aiur, :health_orchestrator_pid_fun, previous_orchestrator)
      if is_nil(previous_preflight), do: Application.delete_env(:aiur, :health_tracker_preflight_fun), else: Application.put_env(:aiur, :health_tracker_preflight_fun, previous_preflight)
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
    Application.put_env(:aiur, :health_tracker_preflight_fun, fn -> :ok end)

    assert request(:get, "/readyz").status == 503
  end

  defp request(method, path) do
    method
    |> conn(path)
    |> Map.put(:host, "localhost")
    |> AiurWeb.Endpoint.call(AiurWeb.Endpoint.init([]))
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
