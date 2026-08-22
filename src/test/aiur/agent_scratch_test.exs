defmodule Aiur.AgentScratchTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentScratch

  setup do
    workspace = Path.join(System.tmp_dir!(), "aiur-scratch-test-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    {:ok, workspace: workspace}
  end

  describe "dir/1" do
    test "is workspace-private, so two concurrent agents never share a staging path" do
      first = AgentScratch.dir("/work/aiur/1573")
      second = AgentScratch.dir("/work/aiur/1583")

      assert first == "/work/aiur/1573/.aiur-runtime/tmp"
      assert second == "/work/aiur/1583/.aiur-runtime/tmp"
      refute first == second
    end
  end

  describe "install/1" do
    test "creates the scratch directory", %{workspace: workspace} do
      assert :ok = AgentScratch.install(workspace)
      assert File.dir?(Path.join(workspace, ".aiur-runtime/tmp"))
    end

    test "is idempotent", %{workspace: workspace} do
      assert :ok = AgentScratch.install(workspace)
      File.write!(Path.join(workspace, ".aiur-runtime/tmp/staged.md"), "body")

      assert :ok = AgentScratch.install(workspace)
      assert File.read!(Path.join(workspace, ".aiur-runtime/tmp/staged.md")) == "body"
    end

    test "refuses to write through a symlinked scratch path", %{workspace: workspace} do
      outside = Path.join(workspace, "outside")
      File.mkdir_p!(outside)
      File.mkdir_p!(Path.join(workspace, ".aiur-runtime"))
      File.ln_s!(outside, Path.join(workspace, ".aiur-runtime/tmp"))

      assert {:error, {:unsafe_agent_scratch_path, _path, :symlink}} = AgentScratch.install(workspace)
    end

    test "leaves a nonexistent workspace root alone" do
      absent = Path.join(System.tmp_dir!(), "aiur-scratch-absent-#{System.pid()}-#{System.unique_integer([:positive])}")

      assert :ok = AgentScratch.install(absent)
      refute File.exists?(absent)
    end

    test "ignores a nil workspace" do
      assert :ok = AgentScratch.install(nil)
    end
  end

  describe "remote_install_script/1" do
    test "creates the same workspace-private path on a worker", %{workspace: workspace} do
      script = AgentScratch.remote_install_script(workspace)

      assert {_output, 0} = System.cmd("sh", ["-lc", script])
      assert File.dir?(Path.join(workspace, ".aiur-runtime/tmp"))
    end

    test "refuses a symlinked scratch path on a worker", %{workspace: workspace} do
      File.mkdir_p!(Path.join(workspace, ".aiur-runtime"))
      File.ln_s!(Path.join(workspace, "outside"), Path.join(workspace, ".aiur-runtime/tmp"))

      assert {_output, 73} = System.cmd("sh", ["-lc", AgentScratch.remote_install_script(workspace)], stderr_to_stdout: true)
    end
  end
end
