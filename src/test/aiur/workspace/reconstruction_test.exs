defmodule Aiur.Workspace.ReconstructionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.{AgentEventLog, Workspace.Reconstruction}
  alias Aiur.Workspace.Provisioner

  setup do
    root = Aiur.TestSupport.tmp_root!("workspace-reconstruction")
    workspace = Path.join(root, "ticket")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace}
  end

  test "preserves prior and concurrent alert events when a staged reconstruction succeeds", %{
    root: root,
    workspace: workspace
  } do
    assert :ok = AgentEventLog.write(workspace, nil, %{event: "alert", last_message: "before reconstruction"})

    assert :ok =
             Reconstruction.run(workspace, fn stage ->
               assert :ok = AgentEventLog.write(workspace, nil, %{event: "alert", last_message: "during reconstruction"})
               File.write!(Path.join(stage, "README.md"), "rebuilt\n")
               :ok
             end)

    assert File.read!(Path.join(workspace, "README.md")) == "rebuilt\n"
    log = File.read!(Path.join([workspace, "logs", "agent.ndjson"]))
    assert log =~ "before reconstruction"
    assert log =~ "during reconstruction"
    assert File.ls!(root) == ["ticket"]
  end

  # #1317: a successful staged clone (e.g. after_create/before_run cloning
  # into the sibling stage dir) was observed landing at the destination as an
  # empty/logs-only workspace instead of the real checkout, with no error
  # anywhere. The suspected mechanism was a concurrent AgentEventLog write
  # recreating `workspace` mid-flight, since only promotion itself (not the
  # whole staging window) held the log lock. This proves the lock now spans
  # the entire reconstruction: a concurrent writer is blocked until the
  # reconstruction finishes, and the promoted content is never dropped.
  test "a concurrent alert write during staging never drops the promoted checkout", %{
    root: root,
    workspace: workspace
  } do
    parent = self()

    reconstruction =
      Task.async(fn ->
        Reconstruction.run(workspace, fn stage ->
          send(parent, :prepare_started)

          receive do
            :continue_prepare -> :ok
          end

          File.write!(Path.join(stage, "README.md"), "rebuilt\n")
          :ok
        end)
      end)

    assert_receive :prepare_started, 5_000

    writer =
      Task.async(fn ->
        AgentEventLog.write(workspace, nil, %{event: "alert", last_message: "concurrent during staging"})
      end)

    # The writer must not observe/recreate `workspace` while the
    # reconstruction is still staging — it has to wait for the same log lock.
    refute Task.yield(writer, 100)

    send(reconstruction.pid, :continue_prepare)

    assert :ok = Task.await(reconstruction, 5_000)
    assert :ok = Task.await(writer, 5_000)

    assert File.read!(Path.join(workspace, "README.md")) == "rebuilt\n"
    assert File.read!(Path.join([workspace, "logs", "agent.ndjson"])) =~ "concurrent during staging"
    assert File.ls!(root) == ["ticket"]
  end

  test "leaves the live logs in place when staged reconstruction fails", %{root: root, workspace: workspace} do
    assert :ok = AgentEventLog.write(workspace, nil, %{event: "alert", last_message: "before failed reconstruction"})

    assert {:error, :clone_failed} =
             Reconstruction.run(workspace, fn _stage ->
               assert :ok = AgentEventLog.write(workspace, nil, %{event: "alert", last_message: "during failed reconstruction"})
               {:error, :clone_failed}
             end)

    log = File.read!(Path.join([workspace, "logs", "agent.ndjson"]))
    assert log =~ "before failed reconstruction"
    assert log =~ "during failed reconstruction"
    assert File.ls!(root) == ["ticket"]
  end

  test "keeps the workspace leaf name inside its sibling stage", %{workspace: workspace} do
    assert :ok =
             Reconstruction.run(workspace, fn stage ->
               assert Path.basename(stage) == Path.basename(workspace)
               refute Path.dirname(stage) == Path.dirname(workspace)
               File.write!(Path.join(stage, "README.md"), "rebuilt\n")
               :ok
             end)
  end

  test "preserves the complete safe logs subtree during promotion", %{workspace: workspace} do
    trace = Path.join([workspace, "logs", "provider", "custom.trace"])
    File.mkdir_p!(Path.dirname(trace))
    File.write!(trace, "before\n")

    assert :ok =
             Reconstruction.run(workspace, fn stage ->
               staged_trace = Path.join([stage, "logs", "provider", "custom.trace"])
               File.mkdir_p!(Path.dirname(staged_trace))
               File.write!(staged_trace, "after\n")
               :ok
             end)

    assert File.read!(Path.join([workspace, "logs", "provider", "custom.trace"])) == "before\nafter\n"
  end

  test "streams logs larger than the copy chunk during promotion", %{workspace: workspace} do
    log = Path.join([workspace, "logs", "provider", "large.trace"])
    chunk = Reconstruction.log_copy_chunk_size()
    previous_size = write_repeated!(log, "before\n", chunk * 128)

    assert :ok =
             Reconstruction.run(workspace, fn stage ->
               staged_log = Path.join([stage, "logs", "provider", "large.trace"])
               staged_size = write_repeated!(staged_log, "after\n", chunk * 128)
               send(self(), {:staged_size, staged_size})
               :ok
             end)

    assert_receive {:staged_size, staged_size}, 5_000
    assert {:ok, %File.Stat{size: size}} = File.stat(log)
    assert size == previous_size + staged_size
    assert File.ls!(Path.dirname(workspace)) == [Path.basename(workspace)]
  end

  test "rolls back the promoted workspace when a streamed log write fails", %{root: root, workspace: workspace} do
    original_log = Path.join([workspace, "logs", "provider", "large.trace"])
    original_readme = Path.join(workspace, "README.md")
    chunk = Reconstruction.log_copy_chunk_size()
    File.mkdir_p!(Path.dirname(original_log))
    File.write!(original_readme, "original\n")
    File.write!(original_log, String.duplicate("before\n", div(chunk, 7) + 2))
    {:ok, writes} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(writes)
    end)

    write_fun = fn output, data ->
      case Agent.get_and_update(writes, fn count -> {count, count + 1} end) do
        0 -> IO.binwrite(output, data)
        _ -> {:error, :simulated_midstream_write_failure}
      end
    end

    log =
      capture_log(fn ->
        assert {:error, {:workspace_log_merge_failed, :simulated_midstream_write_failure}} =
                 Reconstruction.run(
                   workspace,
                   fn stage ->
                     staged_log = Path.join([stage, "logs", "provider", "large.trace"])
                     File.mkdir_p!(Path.dirname(staged_log))
                     File.write!(Path.join(stage, "README.md"), "replacement\n")
                     File.write!(staged_log, "after\n")
                     :ok
                   end,
                   write_fun: write_fun
                 )
      end)

    assert File.read!(original_readme) == "original\n"
    assert File.read!(original_log) =~ "before\n"
    assert File.ls!(root) == ["ticket"]

    # #1317: a promotion failure must be loud, not just a returned tuple that
    # a caller can drop — this was previously the only signal, and the actual
    # incident it papers over left no trace anywhere in the daemon log.
    assert log =~ "Workspace promotion failed"
    assert log =~ "workspace_log_merge_failed"
    assert log =~ ":simulated_midstream_write_failure"
  end

  test "rolls back the promoted workspace when a streamed log write raises", %{root: root, workspace: workspace} do
    original_log = Path.join([workspace, "logs", "provider", "trace.log"])
    original_readme = Path.join(workspace, "README.md")
    File.mkdir_p!(Path.dirname(original_log))
    File.write!(original_readme, "original\n")
    File.write!(original_log, "before\n")

    assert {:error, {:workspace_log_merge_failed, {:log_write_raised, %RuntimeError{}}}} =
             Reconstruction.run(
               workspace,
               fn stage ->
                 File.mkdir_p!(Path.join(stage, "logs"))
                 File.write!(Path.join(stage, "README.md"), "replacement\n")
                 File.write!(Path.join([stage, "logs", "trace.log"]), "after\n")
                 :ok
               end,
               write_fun: fn _output, _data -> raise "simulated write failure" end
             )

    assert File.read!(original_readme) == "original\n"
    assert File.read!(original_log) == "before\n"
    assert File.ls!(root) == ["ticket"]
  end

  test "rejects a staged logs symlink instead of following it during promotion", %{root: root, workspace: workspace} do
    source_log = Path.join([workspace, "logs", "agent.md"])
    outside = Path.join(root, "outside")
    File.mkdir_p!(Path.dirname(source_log))
    File.mkdir_p!(outside)
    File.write!(source_log, "preserve\n")

    assert {:error, {:workspace_log_merge_failed, :unsafe_log_destination}} =
             Reconstruction.run(workspace, fn stage ->
               assert :ok = File.ln_s(outside, Path.join(stage, "logs"))
               :ok
             end)

    assert File.read!(source_log) == "preserve\n"
  end

  test "rejects a nested staged log directory symlink instead of writing through it", %{root: root, workspace: workspace} do
    source_log = Path.join([workspace, "logs", "provider", "custom.trace"])
    outside = Path.join(root, "outside")
    outside_log = Path.join(outside, "custom.trace")
    File.mkdir_p!(Path.dirname(source_log))
    File.mkdir_p!(outside)
    File.write!(source_log, "preserve\n")

    assert {:error, {:workspace_log_merge_failed, :unsafe_log_destination}} =
             Reconstruction.run(workspace, fn stage ->
               staged_logs = Path.join(stage, "logs")
               File.mkdir_p!(staged_logs)
               assert :ok = File.ln_s(outside, Path.join(staged_logs, "provider"))
               :ok
             end)

    assert File.read!(source_log) == "preserve\n"
    refute File.exists?(outside_log)
  end

  test "cold fallback serializes first-pickup event logs until the workspace is ready", %{workspace: workspace} do
    parent = self()
    File.rm_rf!(workspace)

    fallback =
      Task.async(fn ->
        Provisioner.cold_fallback_workspace(workspace, fn ->
          send(parent, :cold_fallback_recheck_entered)

          receive do
            :continue_cold_fallback -> :ok
          end
        end)
      end)

    assert_receive :cold_fallback_recheck_entered, 5_000

    writer =
      Task.async(fn ->
        AgentEventLog.write(workspace, nil, %{
          event: "alert",
          last_message: "first pickup survived fallback"
        })
      end)

    refute Task.yield(writer, 100)
    send(fallback.pid, :continue_cold_fallback)

    assert {:ok, ^workspace, true} = Task.await(fallback)
    assert :ok = Task.await(writer)

    assert File.read!(Path.join([workspace, "logs", "agent.ndjson"])) =~
             "first pickup survived fallback"

    assert File.read!(Path.join([workspace, "logs", "agent.md"])) =~
             "first pickup survived fallback"
  end

  defp write_repeated!(path, line, minimum_size) do
    File.mkdir_p!(Path.dirname(path))
    chunk = String.duplicate(line, div(minimum_size, byte_size(line)) + 1)
    File.write!(path, chunk)
    byte_size(chunk)
  end
end
