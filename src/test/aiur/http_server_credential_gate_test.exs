defmodule Aiur.HttpServerCredentialGateTest do
  use ExUnit.Case, async: false

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

  # Future-regression guards: these intentionally pass on existing production code.
  describe "non-loopback addresses without credentials" do
    for {name, host} <- [
          {"the IPv4 wildcard needs credentials", "0.0.0.0"},
          {"the IPv6 wildcard needs credentials", "::"},
          {"only 127.0.0.1 counts as IPv4 loopback", "127.0.0.2"}
        ] do
      test name do
        assert :ignore =
                 HttpServer.start_link(
                   host: unquote(host),
                   port: 0,
                   dashboard_writable: false,
                   endpoint_start_fun: fn -> {:ok, self()} end
                 )
      end
    end

    test "a writable wildcard bind needs credentials" do
      log =
        capture_log(fn ->
          assert :ignore =
                   HttpServer.start_link(
                     host: "0.0.0.0",
                     port: 0,
                     dashboard_writable: true,
                     endpoint_start_fun: fn -> {:ok, self()} end
                   )
        end)

      assert log =~ "observability.dashboard_writable"
    end
  end

  # Future-regression guard for MP-N2 RQ-TRANSPORT and MP-R3-C2-T01 Transport docs.
  test "the listener is configured for plain HTTP only (MP-N2 transport depends on this)" do
    System.put_env("AIUR_DASHBOARD_USERNAME", "alice")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")

    assert {:ok, pid} =
             HttpServer.start_link(
               host: "127.0.0.1",
               port: 0,
               endpoint_start_fun: fn -> {:ok, self()} end
             )

    assert pid == self()
    config = Application.fetch_env!(:aiur, AiurWeb.Endpoint)
    assert config[:http][:ip] == {127, 0, 0, 1}
    assert config[:http][:port] == 0
    refute Keyword.has_key?(config, :https)
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
    test "dashboard_pages? is written to endpoint config and defaults to on" do
      start = fn opts ->
        capture_log(fn ->
          HttpServer.start_link([host: "127.0.0.1", port: 0, dashboard_writable: false, endpoint_start_fun: fn -> :ignore end] ++ opts)
        end)

        {Application.get_env(:aiur, AiurWeb.Endpoint)[:dashboard_pages], Application.get_env(:aiur, :dashboard_pages)}
      end

      on_exit(fn -> Application.delete_env(:aiur, :dashboard_pages) end)
      assert start.(dashboard_pages?: false) == {false, false}
      assert start.([]) == {true, true}
    end

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

      # `:ignore` here would mean the gate rejected before binding.
      # Anything else (success, bind failure, exit) means the gate
      # let us through.
      refute result == :ignore
    end
  end
end
