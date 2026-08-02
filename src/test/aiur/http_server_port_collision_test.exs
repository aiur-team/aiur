defmodule Aiur.HttpServerPortCollisionTest do
  # Regression for #442: two coexisting aiur instances configured with the same
  # fixed dashboard port (e.g. `server.port: 4000`) must not crash the second
  # BEAM on startup. The second instance's dashboard bind hits `:eaddrinuse`;
  # `HttpServer.start_link` must degrade to `:ignore` (log + no dashboard)
  # instead of returning an error tuple that exhausts the supervisor and brings
  # the node down.
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.HttpServer

  # Occupy a loopback port the way a *first* aiur instance's dashboard socket
  # would, from the perspective of a second instance: a live listener holding
  # 127.0.0.1:<port>. Returns {listen_socket, port}.
  defp occupy_loopback_port do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, reuseaddr: false)
    {:ok, {_ip, port}} = :inet.sockname(listen)
    {listen, port}
  end

  describe "fixed dashboard port already in use" do
    test "start_link degrades to :ignore and logs an actionable warning" do
      {listen, port} = occupy_loopback_port()
      on_exit(fn -> :gen_tcp.close(listen) end)

      log =
        capture_log(fn ->
          assert HttpServer.start_link(host: "127.0.0.1", port: port, dashboard_writable: false) == :ignore
        end)

      assert log =~ "#{port}"
      assert log =~ "already in use"
    end

    test "the supervision tree survives a bound-port dashboard child" do
      {listen, port} = occupy_loopback_port()
      on_exit(fn -> :gen_tcp.close(listen) end)

      children = [
        Supervisor.child_spec(
          {HttpServer, [host: "127.0.0.1", port: port, dashboard_writable: false]},
          id: :collision_http
        )
      ]

      capture_log(fn ->
        # A :one_for_one parent (mirroring Aiur.Supervisor) must start cleanly:
        # the child returns :ignore, which the supervisor treats as "not started"
        # rather than a failure that would exhaust max_restarts and crash the node.
        assert {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
        assert Process.alive?(sup)
        assert HttpServer.bound_port() == nil
        Supervisor.stop(sup)
      end)
    end
  end
end
