defmodule Aiur.Claude.RemoteControlTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.RemoteControl

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
  end

  describe "workspace_slug/1" do
    test "replaces every slash and dot with a dash" do
      assert RemoteControl.workspace_slug("/home/orangekid/code/aiur/workspaces/100") ==
               "-home-orangekid-code-aiur-workspaces-100"

      assert RemoteControl.workspace_slug("/home/orangekid/.tmux") == "-home-orangekid--tmux"
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
        is_integer(first_child) -> first_child
        System.monotonic_time(:millisecond) >= deadline -> nil
        true ->
          Process.sleep(25)
          do_wait_for_child(parent, deadline)
      end
    end

    defp os_alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
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
end
