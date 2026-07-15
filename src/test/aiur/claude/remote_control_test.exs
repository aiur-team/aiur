defmodule Aiur.Claude.RemoteControlTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.RemoteControl

  @pgrep_skip_reason Aiur.TestSupport.pgrep_skip_reason()

  @captured_url_line "Continue coding in the Claude mobile app or https://claude.ai/code/session_01RY7wJRVZgf4RUenZYtSDUz"

  describe "parse_session_url/1 (characterization of the real TUI line)" do
    test "extracts the URL from the captured RC output line" do
      assert RemoteControl.parse_session_url(@captured_url_line) ==
               "https://claude.ai/code/session_01RY7wJRVZgf4RUenZYtSDUz"
    end

    test "returns nil when no URL is present" do
      assert RemoteControl.parse_session_url("[bridge:init] Registered, server environmentId=env_x") == nil
      assert RemoteControl.parse_session_url("") == nil
    end

    test "returns nil for a non-binary line" do
      assert RemoteControl.parse_session_url(nil) == nil
    end
  end

  describe "process liveness probes" do
    test "reports the running BEAM as alive" do
      # The containment loop polls process_alive? before reaping the paused root;
      # a live root must read as alive so a cooperative pause is never force-reaped.
      assert RemoteControl.process_alive?(String.to_integer(System.pid()))
    end

    test "treats a nil or non-positive pid / group as not alive" do
      # A session that never reported a real os pid (nil / 0) has nothing to probe,
      # so both liveness checks read false instead of shelling out to `kill`.
      refute RemoteControl.process_alive?(nil)
      refute RemoteControl.process_alive?(0)
      refute RemoteControl.process_group_alive?(nil)
      refute RemoteControl.process_group_alive?(0)
    end

    test "killing an absent process group short-circuits to :gone" do
      # With no group id to signal, teardown reports the group already gone instead
      # of blocking on a TERM/KILL grace wait for a group that never existed.
      assert RemoteControl.graceful_kill_process_group(nil) == {:ok, :gone}
      assert RemoteControl.graceful_kill_process_group(0) == {:ok, :gone}
    end
  end

  describe "process identity" do
    test "binds a running process to its procfs birth and session" do
      os_pid = System.pid() |> String.to_integer()

      assert {:ok, {:procfs_birth_and_session, start_time, session}} = RemoteControl.process_identity(os_pid)
      assert start_time =~ ~r/^\d+$/
      assert session =~ ~r/^\d+$/
    end

    test "treats missing process identifiers as gone" do
      assert RemoteControl.process_identity(nil) == :gone
      assert RemoteControl.process_identity(0) == :gone
    end
  end

  describe "workspace_slug/1" do
    test "replaces every slash and dot with a dash" do
      assert RemoteControl.workspace_slug("/home/orangekid/code/aiur/workspaces/100") ==
               "-home-orangekid-code-aiur-workspaces-100"

      assert RemoteControl.workspace_slug("/home/orangekid/.tmux") == "-home-orangekid--tmux"
    end
  end

  describe "session_transcript_path/3" do
    test "builds <projects_dir>/<workspace-slug>/<session_id>.jsonl" do
      assert RemoteControl.session_transcript_path("/ws/aiur/613", "abc-123", projects_dir: "/p") ==
               "/p/-ws-aiur-613/abc-123.jsonl"
    end

    test "round-trips with newest_transcript's filename->id read" do
      # The claude CLI names a session's transcript by its id, so resolving the
      # newest transcript and rebuilding its path from the parsed id must point
      # back at the same file (the resume existence-check relies on this).
      dir = Path.join(System.tmp_dir!(), "rc-session-path-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      workspace = "/ws/aiur/613"
      slug_dir = Path.join(dir, RemoteControl.workspace_slug(workspace))
      File.mkdir_p!(slug_dir)
      transcript = Path.join(slug_dir, "session-xyz.jsonl")
      File.write!(transcript, ~s({"cwd":"#{workspace}"}\n))

      session_id =
        slug_dir
        |> RemoteControl.newest_transcript(workspace)
        |> Path.basename()
        |> Path.rootname()

      assert RemoteControl.session_transcript_path(workspace, session_id, projects_dir: dir) == transcript
    end
  end

  describe "ensure_workspace_trusted/2" do
    setup do
      path = Path.join(System.tmp_dir!(), "claude-#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "sets the trust flag when the project key is absent", %{path: path} do
      File.write!(path, Jason.encode!(%{"projects" => %{}}))

      assert :ok = RemoteControl.ensure_workspace_trusted("/work/space", path: path)

      assert get_in(decode(path), ["projects", "/work/space", "hasTrustDialogAccepted"]) == true
    end

    test "creates the file when it does not exist", %{path: path} do
      refute File.exists?(path)

      assert :ok = RemoteControl.ensure_workspace_trusted("/work/space", path: path)
      assert get_in(decode(path), ["projects", "/work/space", "hasTrustDialogAccepted"]) == true
    end

    test "is idempotent and preserves sibling project keys", %{path: path} do
      File.write!(
        path,
        Jason.encode!(%{
          "projects" => %{
            "/work/space" => %{"hasTrustDialogAccepted" => true, "other" => 1},
            "/other" => %{"hasTrustDialogAccepted" => false}
          }
        })
      )

      assert :ok = RemoteControl.ensure_workspace_trusted("/work/space", path: path)

      config = decode(path)
      assert get_in(config, ["projects", "/work/space", "hasTrustDialogAccepted"]) == true
      assert get_in(config, ["projects", "/work/space", "other"]) == 1
      assert get_in(config, ["projects", "/other", "hasTrustDialogAccepted"]) == false
    end

    defp decode(path), do: path |> File.read!() |> Jason.decode!()
  end

  describe "graceful_kill/1" do
    test "blocks until the OS process has actually exited" do
      # Child handles SIGTERM after a deliberate delay (mirrors claude flushing
      # its debug-file on the way down). A correct teardown must not return —
      # and must not delete the debug-file — until that exit completes.
      command = "trap 'sleep 0.25; exit 0' TERM; printf 'up\\n'; while true; do sleep 0.05; done"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(System.find_executable("bash"))},
          [:binary, :exit_status, :stderr_to_stdout, args: [~c"-lc", String.to_charlist(command)], line: 64_000]
        )

      {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
      on_exit(fn -> System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true) end)

      # "up" prints only after the trap is installed — wait for it so SIGTERM
      # can't beat the trap and hit bash's default (instant) disposition.
      assert_receive {^port, {:data, {:eol, "up"}}}, 2_000

      started = System.monotonic_time(:millisecond)
      assert :ok = RemoteControl.graceful_kill(os_pid)
      elapsed = System.monotonic_time(:millisecond) - started

      # Waited out the child's ~250ms shutdown, and the process is gone on return.
      assert elapsed >= 150
      refute match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true))
    end
  end

  describe "graceful_kill_tree/1" do
    @tag skip: @pgrep_skip_reason
    test "reaps the bash wrapper AND its surviving child (the headless orphan)" do
      # Mirror the headless backend: a `bash -lc` wrapper that forks a child
      # it does NOT exec into. Killing only the bash pid leaves that child
      # reparented to init — the exact orphan U7/#109 must prevent. The job
      # is backgrounded so the shell's SIGTERM does not propagate to it.
      command = "sleep 600 & printf 'up\\n'; wait"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(System.find_executable("bash"))},
          [:binary, :exit_status, :stderr_to_stdout, args: [~c"-lc", String.to_charlist(command)], line: 64_000]
        )

      {:os_pid, bash_pid} = :erlang.port_info(port, :os_pid)
      assert_receive {^port, {:data, {:eol, "up"}}}, 2_000

      child_pid = wait_for_child(bash_pid, 2_000)

      on_exit(fn ->
        for p <- [bash_pid, child_pid], is_integer(p) do
          System.cmd("kill", ["-KILL", Integer.to_string(p)], stderr_to_stdout: true)
        end
      end)

      # The child is a real, distinct descendant that single-pid graceful_kill
      # would strand — that is the whole point of the tree variant.
      assert is_integer(child_pid)
      assert child_pid != bash_pid
      assert os_alive?(child_pid)

      assert :ok = RemoteControl.graceful_kill_tree(bash_pid)

      refute os_alive?(bash_pid)
      refute os_alive?(child_pid)
    end

    defp wait_for_child(parent, budget_ms) do
      deadline = System.monotonic_time(:millisecond) + budget_ms
      do_wait_for_child(parent, deadline)
    end

    defp do_wait_for_child(parent, deadline) do
      first_child =
        case System.cmd("pgrep", ["-P", Integer.to_string(parent)], stderr_to_stdout: true) do
          {out, 0} -> out |> String.split() |> Enum.map(&String.to_integer/1) |> List.first()
          _ -> nil
        end

      cond do
        is_integer(first_child) ->
          first_child

        System.monotonic_time(:millisecond) >= deadline ->
          nil

        true ->
          Process.sleep(25)
          do_wait_for_child(parent, deadline)
      end
    end

    defp os_alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
  end

  describe "graceful_kill_process_group/1" do
    test "reaps a child after its session leader exits" do
      # Redirect the backgrounded child's stdio so the session leader can exit
      # and `System.cmd` returns; an inherited stdout pipe would block the call
      # until the child itself exits.
      {out, 0} = System.cmd("setsid", ["sh", "-c", "sleep 600 >/dev/null 2>&1 & echo $!"], stderr_to_stdout: true)
      child_pid = out |> String.trim() |> String.to_integer()

      on_exit(fn ->
        System.cmd("kill", ["-KILL", Integer.to_string(child_pid)], stderr_to_stdout: true)
      end)

      {pgid_out, 0} = System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(child_pid)], stderr_to_stdout: true)
      process_group_id = pgid_out |> String.trim() |> String.to_integer()

      assert RemoteControl.process_group_alive?(process_group_id)
      assert {:ok, :reaped} = RemoteControl.graceful_kill_process_group(process_group_id)
      refute RemoteControl.process_group_alive?(process_group_id)
    end
  end

  describe "reap_orphaned_servers/0" do
    test "sweeps debug files of dead owners but keeps live owners' files" do
      dir = Path.join(System.tmp_dir!(), "aiur-rc")
      File.mkdir_p!(dir)

      # The current BEAM os pid is alive and same-user — its file survives.
      live_pid = List.to_string(:os.getpid())
      live = Path.join(dir, "rc-#{live_pid}-#{System.unique_integer([:positive])}.debug")
      File.write!(live, "")

      # Spawn and reap a child so its pid is reliably dead.
      {out, 0} = System.cmd("bash", ["-lc", "sleep 60 & p=$!; kill -9 $p; wait $p 2>/dev/null; echo $p"])
      dead_pid = String.trim(out)
      dead_n = System.unique_integer([:positive])
      dead = Path.join(dir, "rc-#{dead_pid}-#{dead_n}.debug")
      # claude also leaves a per-session sibling; it must be swept too.
      dead_sibling = Path.join(dir, "rc-#{dead_pid}-#{dead_n}-cse_01XYZ.debug")
      File.write!(dead, "")
      File.write!(dead_sibling, "")

      on_exit(fn ->
        File.rm(live)
        File.rm(dead)
        File.rm(dead_sibling)
      end)

      assert :ok = RemoteControl.reap_orphaned_servers()

      assert File.exists?(live)
      refute File.exists?(dead)
      refute File.exists?(dead_sibling)
    end
  end

  describe "reap_workspace_agents/2" do
    setup do
      # Canonicalize the root so fake `/proc/<pid>/cwd` targets (built from `root`)
      # match the root after reap_workspace_agents canonicalizes it internally —
      # mirroring production, where the kernel reports cwd symlink-resolved.
      raw = Path.join(System.tmp_dir!(), "rwa-root-#{System.unique_integer([:positive])}")

      root =
        case Aiur.PathSafety.canonicalize(raw) do
          {:ok, path} -> path
          _ -> raw
        end

      proc = Path.join(System.tmp_dir!(), "rwa-proc-#{System.unique_integer([:positive])}")
      File.mkdir_p!(proc)
      on_exit(fn -> File.rm_rf(proc) end)
      {:ok, root: root, proc: proc}
    end

    defp fake_proc(proc, pid, comm, cwd) do
      dir = Path.join(proc, Integer.to_string(pid))
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "comm"), comm <> "\n")
      File.ln_s!(cwd, Path.join(dir, "cwd"))
    end

    defp remove_fake_proc(proc, pid) do
      File.rm_rf!(Path.join(proc, Integer.to_string(pid)))
    end

    defp collect_killed(acc) do
      receive do
        {:killed, pid} -> collect_killed([pid | acc])
      after
        0 -> acc
      end
    end

    test "kills every process whose cwd is strictly under the workspace root, regardless of comm",
         %{root: root, proc: proc} do
      # The leak (#453) is the WHOLE agent tree: renamed coding agents, opencode
      # clients, and the mix/beam.smp test children they spawn. None of these have
      # comm `claude`/`node`, so the sweep must be cwd-scoped, not comm-scoped.
      fake_proc(proc, 100, "aiur-claude", Path.join(root, "101"))
      fake_proc(proc, 200, "node", Path.join([root, "101", "sub"]))
      fake_proc(proc, 300, "codex", Path.join(root, "202"))
      fake_proc(proc, 400, "opencode", Path.join(root, "303"))
      fake_proc(proc, 500, "mix", Path.join([root, "404", "src"]))
      fake_proc(proc, 600, "beam.smp", Path.join([root, "404", "src"]))
      # Spared: out-of-tree process, and the workspace root itself (never the root).
      fake_proc(proc, 700, "claude", "/home/op/github/aiur")
      fake_proc(proc, 800, "bash", root)
      File.mkdir_p!(Path.join(proc, "notapid"))

      parent = self()
      kill_fun = fn pid -> send(parent, {:killed, pid}) end

      assert :ok =
               RemoteControl.reap_workspace_agents(root,
                 proc_dir: proc,
                 kill_fun: kill_fun,
                 protected_pids: [],
                 max_sweeps: 1,
                 backoff_ms: 0
               )

      assert Enum.sort(collect_killed([])) == [100, 200, 300, 400, 500, 600]
    end

    test "spares protected pids (the running BEAM and its supervised descendants)",
         %{root: root, proc: proc} do
      fake_proc(proc, 100, "aiur-claude", Path.join(root, "101"))
      fake_proc(proc, 200, "beam.smp", Path.join(root, "202"))

      parent = self()
      kill_fun = fn pid -> send(parent, {:killed, pid}) end

      assert :ok =
               RemoteControl.reap_workspace_agents(root,
                 proc_dir: proc,
                 kill_fun: kill_fun,
                 protected_pids: [200],
                 max_sweeps: 1,
                 backoff_ms: 0
               )

      assert collect_killed([]) == [100]
    end

    test "spares the running BEAM by default (self_pid_tree), reaps the rest",
         %{root: root, proc: proc} do
      self_os_pid = String.to_integer(System.pid())
      # Above Linux's default max pid (2^22), so it can never collide with a real
      # descendant pgrep returns into the protected self-tree.
      other = 2_000_000_000
      fake_proc(proc, self_os_pid, "beam.smp", Path.join(root, "self"))
      fake_proc(proc, other, "aiur-claude", Path.join(root, "other"))

      parent = self()
      kill_fun = fn pid -> send(parent, {:killed, pid}) end

      # protected_pids omitted → default self_pid_tree() must spare the BEAM.
      assert :ok =
               RemoteControl.reap_workspace_agents(root,
                 proc_dir: proc,
                 kill_fun: kill_fun,
                 max_sweeps: 1,
                 backoff_ms: 0
               )

      killed = collect_killed([])
      refute self_os_pid in killed
      assert other in killed
    end

    test "refuses to sweep a dangerously-shallow root", %{proc: proc} do
      fake_proc(proc, 100, "aiur-claude", "/home/agent-101")

      parent = self()
      kill_fun = fn pid -> send(parent, {:killed, pid}) end

      assert :ok =
               RemoteControl.reap_workspace_agents("/home",
                 proc_dir: proc,
                 kill_fun: kill_fun,
                 protected_pids: [],
                 max_sweeps: 1,
                 backoff_ms: 0
               )

      assert collect_killed([]) == []
    end

    test "no-ops when the workspace root has no agents", %{root: root, proc: proc} do
      fake_proc(proc, 300, "claude", "/home/op/github/aiur")

      parent = self()
      kill_fun = fn pid -> send(parent, {:killed, pid}) end

      assert :ok =
               RemoteControl.reap_workspace_agents(root,
                 proc_dir: proc,
                 kill_fun: kill_fun,
                 protected_pids: [],
                 max_sweeps: 1,
                 backoff_ms: 0
               )

      assert collect_killed([]) == []
    end

    test "retries until a process that appears after the first sweep is gone",
         %{root: root, proc: proc} do
      fake_proc(proc, 100, "aiur-claude", Path.join(root, "101"))

      parent = self()

      kill_fun = fn
        100 ->
          send(parent, {:killed, 100})
          remove_fake_proc(proc, 100)
          fake_proc(proc, 200, "beam.smp", Path.join([root, "101", "src"]))

        200 ->
          send(parent, {:killed, 200})
          remove_fake_proc(proc, 200)
      end

      assert :ok =
               RemoteControl.reap_workspace_agents(root,
                 proc_dir: proc,
                 kill_fun: kill_fun,
                 protected_pids: [],
                 max_sweeps: 3,
                 backoff_ms: 0
               )

      assert Enum.sort(collect_killed([])) == [100, 200]
    end

    test "bounds retries when a process remains under the workspace root",
         %{root: root, proc: proc} do
      fake_proc(proc, 100, "beam.smp", Path.join([root, "101", "src"]))

      parent = self()
      kill_fun = fn 100 -> send(parent, {:killed, 100}) end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   RemoteControl.reap_workspace_agents(root,
                     proc_dir: proc,
                     kill_fun: kill_fun,
                     protected_pids: [],
                     max_sweeps: 2,
                     backoff_ms: 0
                   )
        end)

      assert Enum.sort(collect_killed([])) == [100, 100]
      assert log =~ "reap_workspace_agents exhausted"
    end
  end

  # Drives the REAL stop-path sweep against REAL processes and the real /proc
  # filesystem (excluded on platforms without /proc, e.g. macOS — see
  # test_helper.exs). Regression for #453: the box stayed pegged after
  # `aiurdev stop` because workspace-rooted survivors lived on.
  describe "reap_workspace_agents/1 (real processes under a temp workspace root)" do
    @tag :real_proc
    test "reaps a real process rooted under the workspace and spares one outside it" do
      root = Path.join(System.tmp_dir!(), "rwa-live-#{System.unique_integer([:positive])}")
      inside = Path.join(root, "ticket-1/src")
      outside = Path.join(System.tmp_dir!(), "rwa-out-#{System.unique_integer([:positive])}")
      File.mkdir_p!(inside)
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(root) && File.rm_rf(outside) end)

      inside_pid = spawn_sleeper(inside)
      outside_pid = spawn_sleeper(outside)
      on_exit(fn -> System.cmd("kill", ["-KILL", to_string(outside_pid)], stderr_to_stdout: true) end)

      # Exercise the production self-protection path. This test runs inside the
      # same BEAM as the rest of the suite, so disabling protected_pids risks
      # killing supervised test infrastructure if procfs reports a transient
      # cwd under the fixture root.
      assert :ok = RemoteControl.reap_workspace_agents(root)

      assert os_pid_dead?(inside_pid), "expected the workspace-rooted process to be reaped"
      assert os_pid_alive?(outside_pid), "expected the out-of-root process to survive"
    end

    defp spawn_sleeper(cwd) do
      {output, 0} =
        System.cmd("sh", ["-c", "cd \"$1\" || exit 1; sleep 300 >/dev/null 2>&1 & echo $!", "sh", cwd])

      os_pid =
        output
        |> String.trim()
        |> String.to_integer()

      wait_for_proc_cwd(os_pid, cwd)
      os_pid
    end

    defp wait_for_proc_cwd(os_pid, cwd, attempts \\ 20)

    defp wait_for_proc_cwd(_os_pid, _cwd, 0), do: :ok

    defp wait_for_proc_cwd(os_pid, cwd, attempts) do
      case File.read_link("/proc/#{os_pid}/cwd") do
        {:ok, ^cwd} ->
          :ok

        _ ->
          Process.sleep(10)
          wait_for_proc_cwd(os_pid, cwd, attempts - 1)
      end
    end

    defp os_pid_alive?(os_pid) do
      match?({_, 0}, System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true))
    end

    defp os_pid_dead?(os_pid), do: wait_dead(os_pid, 50)

    defp wait_dead(os_pid, 0), do: not os_pid_alive?(os_pid)

    defp wait_dead(os_pid, n) do
      if os_pid_alive?(os_pid) do
        Process.sleep(50)
        wait_dead(os_pid, n - 1)
      else
        true
      end
    end
  end
end
