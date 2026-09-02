defmodule Aiur.HttpServerCredentialGateTest do
  use ExUnit.Case, async: false

  setup {AiurWeb.DashboardCredentialSupport, :isolate}

  import ExUnit.CaptureLog

  alias Aiur.HttpServer

  setup do
    prev_user = System.get_env("AIUR_DASHBOARD_USERNAME")
    prev_pass = System.get_env("AIUR_DASHBOARD_PASSWORD")
    # A passing credential gate lets HttpServer.start_link mutate the shared
    # endpoint application env (dashboard_auth_required, bind config, ...).
    # Capture and restore it so those writes never leak into later tests.
    prev_endpoint = Application.get_env(:aiur, AiurWeb.Endpoint)
    System.delete_env("AIUR_DASHBOARD_USERNAME")
    System.delete_env("AIUR_DASHBOARD_PASSWORD")

    on_exit(fn ->
      restore = fn name, prev ->
        if prev, do: System.put_env(name, prev), else: System.delete_env(name)
      end

      restore.("AIUR_DASHBOARD_USERNAME", prev_user)
      restore.("AIUR_DASHBOARD_PASSWORD", prev_pass)

      case prev_endpoint do
        nil -> Application.delete_env(:aiur, AiurWeb.Endpoint)
        config -> Application.put_env(:aiur, AiurWeb.Endpoint, config)
      end
    end)

    :ok
  end

  describe "non-loopback bind without credentials" do
    test "returns :ignore" do
      result =
        HttpServer.start_link(
          host: "192.0.2.1",
          port: 0,
          orchestrator: Aiur.Orchestrator
        )

      assert result == :ignore
    end
  end

  describe "loopback bind without credentials" do
    test "a read-only loopback listener binds and warns that requests fail closed" do
      log =
        capture_log(fn ->
          HttpServer.start_link(
            host: "127.0.0.1",
            port: 0,
            dashboard_writable: false,
            orchestrator: Aiur.Orchestrator
          )
        end)

      assert log =~ "every request is refused"
      assert log =~ "AIUR_DASHBOARD_USERNAME"
      assert log =~ "AIUR_DASHBOARD_PASSWORD"
    end

    test "a writable loopback listener binds instead of refusing to start (#2376)" do
      # `dashboard_writable` defaults to true, so this is the shipped shape on a
      # stock dev box: missing dashboard credentials must take the bind-and-fail-
      # closed path — the listener comes up and the plug refuses every request —
      # rather than disabling the dashboard entirely.
      log =
        capture_log(fn ->
          result =
            HttpServer.start_link(
              host: "127.0.0.1",
              port: 0,
              dashboard_writable: true,
              orchestrator: Aiur.Orchestrator
            )

          # `:ignore` would mean the credential gate rejected before binding.
          # Anything else (success, bind failure, exit) means the gate let the
          # loopback bind through.
          refute result == :ignore
        end)

      assert log =~ "every request is refused"
      assert log =~ "AIUR_DASHBOARD_USERNAME"
      assert log =~ "AIUR_DASHBOARD_PASSWORD"
    end
  end

  describe "writable dashboard beyond loopback without credentials" do
    test "refuses to start and explains how to configure authentication" do
      log =
        capture_log(fn ->
          assert :ignore =
                   HttpServer.start_link(
                     host: "192.0.2.1",
                     port: 0,
                     dashboard_writable: true,
                     orchestrator: Aiur.Orchestrator
                   )
        end)

      assert log =~ "refusing to start with observability.dashboard_writable enabled"
      assert log =~ "AIUR_DASHBOARD_USERNAME"
      assert log =~ "AIUR_DASHBOARD_PASSWORD"
    end

    test "requires both credentials" do
      System.put_env("AIUR_DASHBOARD_USERNAME", "alice")

      assert capture_log(fn ->
               assert :ignore =
                        HttpServer.start_link(
                          host: "192.0.2.1",
                          port: 0,
                          dashboard_writable: true,
                          orchestrator: Aiur.Orchestrator
                        )
             end) =~ "without basic-auth credentials"
    end
  end

  describe "non-loopback bind with credentials" do
    test "passes the gate (doesn't short-circuit with :ignore)" do
      System.put_env("AIUR_DASHBOARD_USERNAME", "alice")
      System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")
      endpoint_before = Process.whereis(AiurWeb.Endpoint)

      Process.flag(:trap_exit, true)

      # We expect the gate to pass and the Endpoint to then try to bind.
      # Binding to TEST-NET-1 fails with :eaddrnotavail — that's fine,
      # the assertion is "we got past the credential gate", not "we
      # actually bound the port". Trapping exits keeps the test process
      # alive when Endpoint's supervisor cascades the failure.
      result =
        try do
          HttpServer.start_link(
            host: "192.0.2.1",
            port: 0,
            orchestrator: Aiur.Orchestrator
          )
        catch
          :exit, reason -> {:exit, reason}
        end

      if is_nil(endpoint_before), do: await_endpoint_shutdown()

      # `:ignore` here would mean the gate rejected before binding.
      # Anything else (success, bind failure, exit) means the gate
      # let us through.
      refute result == :ignore
    end
  end

  defp await_endpoint_shutdown do
    Enum.reduce_while(1..100, Process.whereis(AiurWeb.Endpoint), fn _, previous ->
      Process.sleep(10)
      current = Process.whereis(AiurWeb.Endpoint)

      if is_nil(previous) and is_nil(current) do
        {:halt, :ok}
      else
        {:cont, current}
      end
    end)
  end
end
