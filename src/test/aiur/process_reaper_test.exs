defmodule Aiur.ProcessReaperTest do
  # async: false — these tests toggle the global :process_reaper_registrations
  # app env, which would race concurrent copies of this module's own tests.
  use ExUnit.Case, async: false

  alias Aiur.ProcessReaper

  # Each test gets its own reaper instance plus registrations force-enabled
  # for the duration (config disables them in test so library code never
  # registers into the real singleton).
  setup do
    name = Module.concat(__MODULE__, :"Inst#{System.unique_integer([:positive])}")
    {:ok, _pid} = start_supervised({ProcessReaper, name: name})

    previous = Application.get_env(:aiur, :process_reaper_registrations)
    Application.put_env(:aiur, :process_reaper_registrations, true)
    on_exit(fn -> Application.put_env(:aiur, :process_reaper_registrations, previous) end)

    %{reaper: name}
  end

  defp recording_killers(test_pid) do
    [
      kill_tree: fn pid -> send(test_pid, {:killed_tree, pid}) end,
      kill_pane: fn pane -> send(test_pid, {:killed_pane, pane}) end,
      cmdline_reader: fn _pid -> {:ok, "matches-everything"} end
    ]
  end

  test "reaps only the requested kinds and empties their entries", %{reaper: reaper} do
    tp = self()
    :ok = ProcessReaper.register(reaper, :agent, {:os_pid, 111}, [])
    :ok = ProcessReaper.register(reaper, :agent, {:pane, "%9"}, [])
    :ok = ProcessReaper.register(reaper, :serve, {:os_pid, 222}, [])

    :ok = ProcessReaper.reap(reaper, [:agent], recording_killers(tp))

    assert_receive {:killed_tree, 111}
    assert_receive {:killed_pane, "%9"}
    refute_receive {:killed_tree, 222}, 50

    # The :serve entry survived the :agent sweep and reaps later.
    :ok = ProcessReaper.reap(reaper, [:serve], recording_killers(tp))
    assert_receive {:killed_tree, 222}
  end

  test "string pids normalize to integers at registration", %{reaper: reaper} do
    tp = self()
    :ok = ProcessReaper.register(reaper, :agent, {:os_pid, "4242"}, [])

    :ok = ProcessReaper.reap(reaper, [:agent], recording_killers(tp))
    assert_receive {:killed_tree, 4242}
  end

  test "entries returns normalized registered refs for observers", %{reaper: reaper} do
    :ok =
      ProcessReaper.register(reaper, :agent, {:os_pid, "4242"},
        comm: "codex",
        ticket: "930",
        backend: "codex",
        remote: false
      )

    :ok = ProcessReaper.register(reaper, :serve, {:os_pid, 77}, comm: "opencode")

    assert {{:os_pid, 4242}, :agent, %{comm: "codex", ticket: "930", backend: "codex", remote: false}} in ProcessReaper.entries(reaper)

    assert {{:os_pid, 77}, :serve, %{comm: "opencode"}} in ProcessReaper.entries(reaper)
  end

  test "nil and garbage refs are ignored", %{reaper: reaper} do
    tp = self()
    :ok = ProcessReaper.register(reaper, :agent, {:os_pid, nil}, [])
    :ok = ProcessReaper.register(reaper, :agent, {:os_pid, "not-a-pid"}, [])

    :ok = ProcessReaper.reap(reaper, [:agent], recording_killers(tp))
    refute_receive {:killed_tree, _}, 50
  end

  test "unregistered refs are not killed", %{reaper: reaper} do
    tp = self()
    :ok = ProcessReaper.register(reaper, :agent, {:os_pid, 111}, [])
    :ok = ProcessReaper.unregister(reaper, {:os_pid, 111})

    :ok = ProcessReaper.reap(reaper, [:agent], recording_killers(tp))
    refute_receive {:killed_tree, 111}, 50
  end

  test "cmdline guard skips a recycled pid but kills a matching one", %{reaper: reaper} do
    tp = self()
    :ok = ProcessReaper.register(reaper, :agent, {:os_pid, 111}, comm: "codex")
    :ok = ProcessReaper.register(reaper, :agent, {:os_pid, 222}, comm: "claude")

    killers = [
      kill_tree: fn pid -> send(tp, {:killed_tree, pid}) end,
      kill_pane: fn _ -> :ok end,
      cmdline_reader: fn
        111 -> {:ok, "vim some-file"}
        222 -> {:ok, "bash -lc claude --app-server"}
      end
    ]

    :ok = ProcessReaper.reap(reaper, [:agent], killers)
    refute_receive {:killed_tree, 111}, 50
    assert_receive {:killed_tree, 222}
  end

  test "an unreadable cmdline means the process is gone — no kill", %{reaper: reaper} do
    tp = self()
    :ok = ProcessReaper.register(reaper, :agent, {:os_pid, 111}, comm: "codex")

    killers = [
      kill_tree: fn pid -> send(tp, {:killed_tree, pid}) end,
      kill_pane: fn _ -> :ok end,
      cmdline_reader: fn _ -> {:error, :enoent} end
    ]

    :ok = ProcessReaper.reap(reaper, [:agent], killers)
    refute_receive {:killed_tree, 111}, 50
  end

  test "a raising killer never stops the sweep", %{reaper: reaper} do
    tp = self()
    :ok = ProcessReaper.register(reaper, :agent, {:os_pid, 111}, [])
    :ok = ProcessReaper.register(reaper, :agent, {:os_pid, 222}, [])

    killers = [
      kill_tree: fn
        111 -> raise "boom"
        pid -> send(tp, {:killed_tree, pid})
      end,
      kill_pane: fn _ -> :ok end,
      cmdline_reader: fn _ -> {:ok, "x"} end
    ]

    :ok = ProcessReaper.reap(reaper, [:agent], killers)
    assert_receive {:killed_tree, 222}
  end

  test "double reap no-ops; draining reap kills late registrations", %{reaper: reaper} do
    tp = self()
    :ok = ProcessReaper.register(reaper, :agent, {:os_pid, 111}, [])

    :ok = ProcessReaper.reap(reaper, [:agent], recording_killers(tp) ++ [drain: true])
    assert_receive {:killed_tree, 111}

    :ok = ProcessReaper.reap(reaper, [:agent], recording_killers(tp) ++ [drain: true])
    refute_receive {:killed_tree, _}, 50

    # Draining latched: a late registration is killed on arrival. The
    # draining kill uses the default killers, so target a certainly-dead
    # pid whose /proc cmdline is unreadable (guard skips the real kill).
    :ok = ProcessReaper.register(reaper, :agent, {:os_pid, 2_147_480_000}, comm: "never-matches")
    refute_receive {:killed_tree, _}, 50
  end

  test "a drain:false reap does NOT latch draining (orchestrator-restart path)", %{reaper: reaper} do
    tp = self()
    :ok = ProcessReaper.register(reaper, :agent, {:os_pid, 111}, [])
    :ok = ProcessReaper.reap(reaper, [:agent], recording_killers(tp))
    assert_receive {:killed_tree, 111}

    # New registration after a non-draining reap registers normally and is
    # reapable later — agent spawning is not bricked.
    :ok = ProcessReaper.register(reaper, :agent, {:os_pid, 333}, [])
    :ok = ProcessReaper.reap(reaper, [:agent], recording_killers(tp))
    assert_receive {:killed_tree, 333}
  end

  test "registrations no-op when disabled by config", %{reaper: reaper} do
    tp = self()
    Application.put_env(:aiur, :process_reaper_registrations, false)

    :ok = ProcessReaper.register(reaper, :agent, {:os_pid, 111}, [])
    :ok = ProcessReaper.reap(reaper, [:agent], recording_killers(tp))
    refute_receive {:killed_tree, _}, 50
  end

  test "register/unregister/reap survive a missing server" do
    assert :ok = ProcessReaper.register(:nonexistent_reaper, :agent, {:os_pid, 111}, [])
    assert :ok = ProcessReaper.unregister(:nonexistent_reaper, {:os_pid, 111})
    assert :ok = ProcessReaper.reap(:nonexistent_reaper, [:agent], [])
    assert [] = ProcessReaper.entries(:nonexistent_reaper)
  end

  # The reaper traps exits so terminate/2 runs on teardown, which means it also
  # receives `{:EXIT, _, _}` for every dying port/process. Those exits (and any
  # stray info message) must be swallowed: without a handle_info clause the
  # GenServer default handler error-logs each one, and a burst of subprocess
  # deaths would flood the log and grow the mailbox until the node dies (#794).
  test "trapped exits and stray messages do not crash the reaper", %{reaper: reaper} do
    pid = GenServer.whereis(reaper)

    send(pid, {:EXIT, self(), :normal})
    send(pid, {:EXIT, self(), :killed})
    send(pid, :some_unexpected_message)

    # A successful call proves the process stayed alive and drained its mailbox.
    assert Process.alive?(pid)
    assert [] = ProcessReaper.entries(reaper)
  end

  describe "AIUR_AGENT_TMPFILE pidfile (launcher-side crash reaper feed)" do
    setup do
      path = Path.join(System.tmp_dir!(), "aiur-agents-#{System.unique_integer([:positive])}")
      File.write!(path, "")
      System.put_env("AIUR_AGENT_TMPFILE", path)

      on_exit(fn ->
        System.delete_env("AIUR_AGENT_TMPFILE")
        File.rm(path)
      end)

      %{pidfile: path}
    end

    test "appends an agent os_pid with its comm guard", %{reaper: reaper, pidfile: path} do
      :ok = ProcessReaper.register(reaper, :agent, {:os_pid, 4321}, comm: "claude")

      assert wait_for_lines(path) == ["pid 4321 claude"]
    end

    test "appends an agent os_pid with no comm as a bare line", %{reaper: reaper, pidfile: path} do
      :ok = ProcessReaper.register(reaper, :agent, {:os_pid, 99}, [])

      assert wait_for_lines(path) == ["pid 99"]
    end

    test "appends an agent pane ref", %{reaper: reaper, pidfile: path} do
      :ok = ProcessReaper.register(reaper, :agent, {:pane, "%7"}, [])

      assert wait_for_lines(path) == ["pane %7"]
    end

    test "does not record :serve entries (handled by session tmpfile)", %{reaper: reaper, pidfile: path} do
      :ok = ProcessReaper.register(reaper, :serve, {:os_pid, 555}, comm: "opencode")
      # A later agent registration proves the writer ran but skipped the serve.
      :ok = ProcessReaper.register(reaper, :agent, {:os_pid, 556}, comm: "codex")

      assert wait_for_lines(path) == ["pid 556 codex"]
    end

    test "no-ops cleanly when the env var is unset", %{reaper: reaper, pidfile: path} do
      System.delete_env("AIUR_AGENT_TMPFILE")
      :ok = ProcessReaper.register(reaper, :agent, {:os_pid, 1}, comm: "claude")

      # Give the GenServer a beat; the file must stay empty.
      :ok = ProcessReaper.reap(reaper, [], [])
      assert File.read!(path) == ""
    end
  end

  # The append happens inside the GenServer after the call returns, so poll.
  defp wait_for_lines(path, attempts \\ 50) do
    lines = path |> File.read!() |> String.split("\n", trim: true)

    cond do
      lines != [] ->
        lines

      attempts == 0 ->
        []

      true ->
        Process.sleep(10)
        wait_for_lines(path, attempts - 1)
    end
  end
end
