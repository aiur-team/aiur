defmodule Aiur.HttpServerPortCollisionTest do
  # Regression for #442: two coexisting aiur instances configured with the same
  # fixed dashboard port (e.g. `server.port: 4000`) must not crash the second
  # BEAM on startup. The second instance's dashboard bind hits `:eaddrinuse`;
  # `HttpServer.start_link` must degrade to `:ignore` (log + no dashboard)
  # instead of returning an error tuple that exhausts the supervisor and brings
  # the node down.
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.{AlertFeed, AlertLedger, HttpServer, SupervisionHealth}

  defmodule SiblingWorker do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)
    def init(:ok), do: {:ok, :running}
  end

  # Occupy a loopback port the way a *first* aiur instance's dashboard socket
  # would, from the perspective of a second instance: a live listener holding
  # 127.0.0.1:<port>. Returns {listen_socket, port}.
  defp occupy_loopback_port do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, reuseaddr: false)
    {:ok, {_ip, port}} = :inet.sockname(listen)
    {listen, port}
  end

  describe "fixed dashboard port already in use" do
    # Characterization (also passes on pre-fix `main`): `main`'s pre-bind probe
    # already degraded to `:ignore` with the same warning text. Documents the
    # operator-facing contract; the `endpoint_start_fun` injection tests below
    # are the regression cover for this change's real-failure classification.
    test "start_link degrades to :ignore and logs an explicit, actionable startup message" do
      {listen, port} = occupy_loopback_port()
      on_exit(fn -> :gen_tcp.close(listen) end)

      log =
        capture_log(fn ->
          assert HttpServer.start_link(host: "127.0.0.1", port: port, dashboard_writable: false) == :ignore
        end)

      assert log =~ "#{port}"
      assert log =~ "already in use"
      assert log =~ "another aiur instance"
      assert log =~ "Dashboard disabled for this instance"
      assert log =~ "agents still run"
      assert log =~ "server.port"
    end

    # Characterization (also passes on pre-fix `main`): the `:one_for_one`
    # supervisor treating `:ignore` as "not started" predates this change.
    # Kept to document the sibling-liveness contract — a second instance's
    # supervisor and workers survive the missing dashboard.
    test "the supervision tree survives a bound-port dashboard child" do
      {listen, port} = occupy_loopback_port()
      on_exit(fn -> :gen_tcp.close(listen) end)

      children = [
        {SiblingWorker, name: nil},
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

        assert Enum.any?(Supervisor.which_children(sup), fn
                 {SiblingWorker, pid, :worker, _modules} -> is_pid(pid) and Process.alive?(pid)
                 _child -> false
               end)

        assert HttpServer.bound_port() == nil
        Supervisor.stop(sup)
      end)
    end

    # Regression cover for this change: fails on pre-fix `main`, whose nested
    # `:eaddrinuse` classification returned the raw error instead of degrading.
    test "a nested listener bind collision still degrades" do
      {listen, port} = occupy_loopback_port()
      :gen_tcp.close(listen)

      log =
        capture_log(fn ->
          assert HttpServer.start_link(
                   host: "127.0.0.1",
                   port: port,
                   dashboard_writable: false,
                   endpoint_start_fun: fn -> {:error, {:shutdown, {:failed_to_start_child, :listener, :eaddrinuse}}} end
                 ) == :ignore
        end)

      assert log =~ "port #{port} is already in use"
      assert log =~ "Dashboard disabled for this instance"
    end

    # Characterization (also passes on pre-fix `main`): `SupervisionHealth` and
    # the alert ledger are untouched by this diff. Kept because it documents the
    # real operator path — `Aiur.Supervisor` reports `Aiur.HttpServer DOWN` to a
    # dashboard-independent ledger, so a missing dashboard surfaces somewhere
    # the operator can still see it.
    test "the missing dashboard reaches the dashboard-independent alert ledger" do
      {listen, port} = occupy_loopback_port()
      log_root = Aiur.TestSupport.tmp_root!("aiur-http-collision-alert")
      previous_log_file = Application.get_env(:aiur, :log_file)
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

      on_exit(fn ->
        :gen_tcp.close(listen)

        if previous_log_file do
          Application.put_env(:aiur, :log_file, previous_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end

        File.rm_rf!(log_root)
      end)

      specs = [
        {SiblingWorker, name: nil},
        Supervisor.child_spec(
          {HttpServer, [host: "127.0.0.1", port: port, dashboard_writable: false]},
          id: HttpServer
        )
      ]

      capture_log(fn ->
        assert {:ok, supervisor} = Supervisor.start_link(specs, strategy: :one_for_one)

        on_exit(fn ->
          if Process.alive?(supervisor) do
            try do
              Supervisor.stop(supervisor)
            catch
              :exit, _reason -> :ok
            end
          end
        end)

        assert {:ok, health} =
                 SupervisionHealth.start_link(
                   name: nil,
                   supervisor: supervisor,
                   expected_children: specs,
                   check_interval: 60_000,
                   alert_opts: [workspace: Path.join(log_root, "workspace")]
                 )

        assert {:ok, %{missing: [%{id: HttpServer}]}} = SupervisionHealth.status(health)

        assert Enum.any?(AlertFeed.list(ledger_paths: [AlertLedger.path()]), fn alert ->
                 alert["topic"] == "system.supervision.degraded" and
                   alert["needs_attention"] == true and
                   alert["message"] =~ "Aiur.HttpServer DOWN"
               end)
      end)
    end

    test "a degraded start from a non-trapping caller leaves the mailbox clean" do
      {listen, port} = occupy_loopback_port()
      on_exit(fn -> :gen_tcp.close(listen) end)

      # Guard the premise: this must start from a non-trapping process, because
      # under `Aiur.Supervisor` the caller already traps and the `trap_exit`
      # flip in `start_endpoint/1` would be a no-op.
      assert Process.info(self(), :trap_exit) == {:trap_exit, false}

      capture_log(fn ->
        assert HttpServer.start_link(host: "127.0.0.1", port: port, dashboard_writable: false) == :ignore
      end)

      # The `after` block must restore the caller's non-trapping flag...
      assert Process.info(self(), :trap_exit) == {:trap_exit, false}
      # ...and the failed endpoint child's exit must be drained, not swallowed.
      assert Process.info(self(), :messages) == {:messages, []}
    end

    test "a degraded start drains the failed endpoint child's exit from the caller mailbox" do
      {listen, port} = occupy_loopback_port()
      :gen_tcp.close(listen)

      # A real endpoint start returns this failure shape when Bandit cannot
      # bind. Inject it with a linked child that actually dies with the same
      # reason, so the caller's mailbox really receives an `{:EXIT, ...}` that
      # `drain_failed_start_exit/1` must consume.
      reason = {:shutdown, {:failed_to_start_child, :listener, :eaddrinuse}}

      log =
        capture_log(fn ->
          assert HttpServer.start_link(
                   host: "127.0.0.1",
                   port: port,
                   dashboard_writable: false,
                   endpoint_start_fun: fn ->
                     spawn_link(fn -> exit(reason) end)
                     {:error, reason}
                   end
                 ) == :ignore
        end)

      assert log =~ "already in use"
      # Exit signals are delivered a beat after the child dies; the drain must
      # wait for and consume it rather than leaving a stale message behind.
      assert Process.info(self(), :messages) == {:messages, []}
    end
  end
end
