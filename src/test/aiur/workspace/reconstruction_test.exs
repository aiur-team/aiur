defmodule Aiur.Workspace.ReconstructionTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentEventLog, Workspace.Reconstruction}
  alias Aiur.Workspace.Provisioner

  setup do
    root = Path.join(System.tmp_dir!(), "workspace-reconstruction-#{System.unique_integer([:positive])}")
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

    assert_receive {:staged_size, staged_size}
    assert {:ok, %File.Stat{size: size}} = File.stat(log)
    assert size == previous_size + staged_size
    assert File.ls!(Path.dirname(workspace)) == [Path.basename(workspace)]
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

    assert_receive :cold_fallback_recheck_entered

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
