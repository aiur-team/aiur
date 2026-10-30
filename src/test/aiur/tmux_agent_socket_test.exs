defmodule Aiur.TmuxAgentSocketTest do
  use ExUnit.Case, async: true
  alias Aiur.Tmux
  alias Aiur.Tmux.Socket

  test "agent calls target their own server despite colliding pane ids" do
    socket = "aiur-unit-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
    agent_socket = socket <> "-agents"
    {:ok, server} = start_supervised({Tmux, session: socket})
    daemon = {:socket, server, socket}
    agent = {:socket, server, agent_socket}

    on_exit(fn ->
      for name <- [socket, agent_socket], do: System.cmd("tmux", ["-L", name, "kill-server"], stderr_to_stdout: true)
    end)

    assert {:ok, daemon_pane} = Tmux.new_hidden_window(daemon, "daemon", "sleep 120")
    assert {:ok, agent_pane} = timed_tmux(server, fn -> Tmux.new_hidden_window_with_env(agent, "aiur-repl-test", "sleep 120", [{"REPL_SOCKET_TEST", "yes"}]) end)
    assert daemon_pane == agent_pane
    assert {:ok, daemon_pid} = Tmux.pane_pid(daemon, daemon_pane)
    assert {:ok, agent_pid} = Tmux.pane_pid(agent, agent_pane)
    assert daemon_pid != agent_pid
    assert {:ok, [{"daemon", ^daemon_pane}]} = Tmux.list_windows(daemon)
    assert {:ok, [{"aiur-repl-test", ^agent_pane}]} = Tmux.list_windows(agent)
    assert :ok = Tmux.set_pane_title(agent, agent_pane, "agent only")
    assert {"agent only\n", 0} = System.cmd("tmux", ["-L", agent_socket, "display-message", "-p", "-t", agent_pane, "\#{pane_title}"])
    assert :ok = Tmux.kill_pane(agent, agent_pane)
    assert {:ok, ^daemon_pid} = Tmux.pane_pid(daemon, daemon_pane)
  end

  test "attached REPL Ctrl+C interrupts its process and Ctrl+Q detaches without killing agents" do
    socket = "aiur-bind-unit-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}-agents"
    wrapper = socket <> "-driver"
    conf = Path.expand("../../../packaging/npm/aiur-cli/share/aiur.tmux.conf", __DIR__)
    {:ok, server} = start_supervised({Tmux, session: socket})
    agent = {:socket, server, socket}

    on_exit(fn ->
      for name <- [socket, wrapper], do: System.cmd("tmux", ["-L", name, "kill-server"], stderr_to_stdout: true)
    end)

    assert {_, 0} = System.cmd("tmux", ["-L", socket, "-f", conf, "new-session", "-d", "-s", socket, "sleep 120"])
    command = "bash -c 'trap \"echo INT_SEEN\" INT; echo READY; while :; do sleep 0.05; done'"
    assert {:ok, pane} = Tmux.new_hidden_window(agent, "repl", command)
    assert {_, 0} = System.cmd("tmux", ["-L", socket, "select-window", "-t", socket <> ":repl"])
    assert {_, 0} = System.cmd("tmux", ["-L", wrapper, "new-session", "-d", "-s", "driver", "exec tmux -L '#{socket}' attach-session -t '#{socket}'"])
    assert eventually(fn -> match?({output, 0} when output != "", System.cmd("tmux", ["-L", socket, "list-clients"])) end)
    assert {_, 0} = System.cmd("tmux", ["-L", wrapper, "send-keys", "-t", "driver", "C-c"])

    assert eventually(fn ->
             case Tmux.capture_pane(agent, pane) do
               {:ok, lines} -> Enum.any?(lines, &String.contains?(&1, "INT_SEEN"))
               _ -> false
             end
           end)

    assert {_, 0} = System.cmd("tmux", ["-L", wrapper, "send-keys", "-t", "driver", "C-q"])
    assert eventually(fn -> System.cmd("tmux", ["-L", socket, "list-clients"]) == {"", 0} end)
    assert {:ok, _pid} = Tmux.pane_pid(agent, pane)
  end

  # #7282 diagnostic: an isolated trace session times every tmux exec the Tmux server runs
  # during `fun`, and prints them when the call fails or takes over 5 s.
  defp timed_tmux(server, fun) do
    session = :trace.session_create(:tmux_agent_socket_diag, self(), [])
    :trace.function(session, {System, :cmd, 3}, [{:_, [], [{:return_trace}]}], [:global])
    :trace.process(session, server, true, [:call, :monotonic_timestamp])
    started = System.monotonic_time()
    result = fun.()
    elapsed = System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
    :trace.session_destroy(session)
    execs = drain_tmux_trace([])
    if not match?({:ok, _}, result) or elapsed > 5_000, do: IO.puts(tmux_report(result, elapsed, execs))
    result
  end

  defp drain_tmux_trace(acc) do
    receive do
      {:trace_ts, _pid, :call, {System, :cmd, [_bin, args, _opts]}, ts} -> drain_tmux_trace([{:call, args, ts} | acc])
      {:trace_ts, _pid, :return_from, {System, :cmd, 3}, {_out, status}, ts} -> drain_tmux_trace([{:return, status, ts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp tmux_report(result, elapsed, execs) do
    {nproc, _} = System.cmd("nproc", [])
    loadavg = File.read!("/proc/loadavg")
    ms = &System.convert_time_unit(&1, :native, :millisecond)

    lines =
      execs
      |> Enum.chunk_while(
        nil,
        fn
          {:call, args, t0}, nil -> {:cont, {args, t0}}
          {:return, status, t1}, {args, t0} -> {:cont, "#{ms.(t1 - t0)} ms exit=#{status} tmux #{Enum.join(args, " ")}", nil}
        end,
        fn
          nil -> {:cont, nil}
          {args, _t0} -> {:cont, "still running exit=none tmux #{Enum.join(args, " ")}", nil}
        end
      )

    Enum.join(["tmux-diag #7282: #{inspect(result)} after #{elapsed} ms; nproc=#{String.trim(nproc)} loadavg=#{String.trim(loadavg)}" | Enum.map(lines, &("tmux-diag   " <> &1))], "\n")
  end

  defp eventually(check, remaining \\ 100)
  defp eventually(_check, 0), do: false

  defp eventually(check, remaining) do
    if check.(),
      do: true,
      else:
        (
          Process.sleep(20)
          eventually(check, remaining - 1)
        )
  end

  test "attach command names the recorded socket and pane" do
    assert Socket.attach_command(%{repl_pane_id: "%9", repl_tmux_socket: "run-agents"}) ==
             "tmux -L 'run-agents' select-pane -t '%9' \\; attach-session"

    assert Socket.attach_command(%{}) == nil
    assert Socket.pane_ref({:socket, self(), "run-agents"}, "%9") == {:pane, "%9", "run-agents"}
  end
end
