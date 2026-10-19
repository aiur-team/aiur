defmodule Aiur.TestCleanupTest do
  # Mutates global :aiur application env, so it cannot run async.
  use ExUnit.Case, async: false

  alias Aiur.{Config.Paths, RepoBase.StateTree}
  alias Aiur.TestCleanup

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-test-cleanup")
    File.mkdir_p!(Path.join(root, "state"))
    previous_repo_root = Application.get_env(:aiur, :repo_base_root)
    # on-exit-rm-rf: allow the helper under test must not clean up after itself
    on_exit(fn ->
      if previous_repo_root,
        do: Application.put_env(:aiur, :repo_base_root, previous_repo_root),
        else: Application.delete_env(:aiur, :repo_base_root)

      TestCleanup.rm_rf!(root)
    end)

    %{root: root}
  end

  test "refuses to remove a directory an app env key still points into", %{root: root} do
    Application.put_env(:aiur, :test_cleanup_probe_dir, Path.join(root, "state"))
    on_exit(fn -> Application.delete_env(:aiur, :test_cleanup_probe_dir) end)

    assert_raise RuntimeError, ~r/:test_cleanup_probe_dir.* still points into it/, fn ->
      TestCleanup.rm_rf!(root)
    end

    assert File.dir?(root)

    Application.delete_env(:aiur, :test_cleanup_probe_dir)
    assert :ok = TestCleanup.rm_rf!(root)
    refute File.exists?(root)
  end

  # A real writer process loses or wins each removal by scheduling luck, so on
  # a loaded host it can also go quiet for a whole retry window and look
  # stopped. This stages the same sequence without the clock: the removal
  # loses to the writer `losses` times, then wins, and for as long as the
  # writer is `alive?` it puts its file straight back.
  defp racing_rm(file, losses, alive?) do
    calls = :counters.new(1, [])

    fn path ->
      :counters.add(calls, 1, 1)
      lost? = :counters.get(calls, 1) <= losses
      result = if lost?, do: {:error, :eexist, path}, else: File.rm_rf(path)

      if lost? or alive? do
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, "x", [:append])
      end

      result
    end
  end

  test "waits out a writer that stops after winning a few races", %{root: root} do
    file = Path.join(root, "state/live.log")

    assert :ok = TestCleanup.rm_rf!(root, rm: racing_rm(file, 3, false))
    refute File.exists?(root)
  end

  test "raises naming the file of a writer that never stops, even though removals succeed", %{root: root} do
    file = Path.join(root, "state/live.log")

    error = assert_raise RuntimeError, fn -> TestCleanup.rm_rf!(root, rm: racing_rm(file, 1, true)) end
    assert error.message =~ "it reappeared after removal after 40 attempts"
    assert error.message =~ "or they cannot be deleted): [#{inspect(file)}]"
  end

  test "checks the first successful removal for a directory that comes back", %{root: root} do
    file = Path.join(root, "state/live.log")

    error =
      assert_raise RuntimeError, fn ->
        TestCleanup.rm_rf!(root, rm: racing_rm(file, 0, true))
      end

    assert error.message =~ "it reappeared after removal after 40 attempts"
    assert error.message =~ "or they cannot be deleted): [#{inspect(file)}]"
  end

  # Regression guard for the reappearance retry already in `TestCleanup`, driven
  # by a real `StateTree` writer. The #5104 fix itself (stopping leaked runner
  # tasks) is covered by `Aiur.TestSupport.RunnerTasksTest`.
  test "existing reappearance retry outlasts a live repo state tree writer", %{root: root} do
    Application.put_env(:aiur, :repo_base_root, root)
    parent = self()
    node = Paths.repo_state_path("test-org/test-repo")

    writer =
      spawn(fn ->
        send(parent, :writer_started)
        writer_loop(parent, node)
      end)

    assert_receive :writer_started, 1000
    on_exit(fn -> if Process.alive?(writer), do: Process.exit(writer, :kill) end)
    removals = :counters.new(1, [])

    assert :ok =
             TestCleanup.rm_rf!(root,
               unset: [:repo_base_root],
               rm: fn path ->
                 result = File.rm_rf(path)
                 :counters.add(removals, 1, 1)

                 if Process.alive?(writer) do
                   send(writer, {:write, self()})
                   receive do: ({:write_finished, ^writer} -> :ok)

                   if :counters.get(removals, 1) == 3 do
                     send(writer, {:stop_after, 3, self()})
                     receive do: ({:writer_stopped, ^writer} -> :ok)
                   end
                 end

                 result
               end
             )

    refute Process.alive?(writer)
    refute File.exists?(root)
    assert :counters.get(removals, 1) == 4
  end

  defp writer_loop(parent, node, writes \\ 0) do
    receive do
      {:write, caller} ->
        :ok = StateTree.ensure_state_tree_at(node)
        send(caller, {:write_finished, self()})
        writer_loop(parent, node, writes + 1)

      {:stop_after, count, caller} when writes >= count ->
        send(caller, {:writer_stopped, self()})
        :ok

      :stop ->
        :ok
    end
  end

  test "unset deletes the named env keys before the guard", %{root: root} do
    Application.put_env(:aiur, :test_cleanup_probe_dir, root)
    on_exit(fn -> Application.delete_env(:aiur, :test_cleanup_probe_dir) end)

    assert :ok = TestCleanup.rm_rf!(root, unset: [:test_cleanup_probe_dir])
    assert :error = Application.fetch_env(:aiur, :test_cleanup_probe_dir)
    refute File.exists?(root)
  end

  test "reports a failure no writer causes at once, under its own reason", %{root: root} do
    held = Path.join(root, "state")
    File.chmod!(root, 0o500)
    on_exit(fn -> File.chmod(root, 0o700) end)

    {micros, error} = :timer.tc(fn -> assert_raise RuntimeError, fn -> TestCleanup.rm_rf!(held) end end)

    assert error.message == "cannot remove #{held}: :eacces at #{held}"
    assert micros < 1_000_000
    assert File.dir?(held)
  end
end
