defmodule Aiur.AgentScratchTest do
  import Bitwise
  use ExUnit.Case, async: true

  alias Aiur.{AgentEnvironment, AgentScratch}
  alias Aiur.Config.CodexSandboxPolicy

  setup do
    workspace = Aiur.TestSupport.tmp_root!("aiur-scratch-test")
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)
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

  describe "MCP socket directory" do
    test "is short, stable per workspace, and created with private permissions", %{workspace: workspace} do
      opts = [runtime_root: "/tmp", user_id: "1"]
      path = AgentScratch.mcp_socket_dir(workspace, opts)
      assert byte_size(path) < 80
      assert path == AgentScratch.mcp_socket_dir(workspace, opts)
      assert [{~c"AIUR_MCP_SOCKET_DIR", value}] = AgentScratch.mcp_socket_env(workspace, opts)
      actual_path = to_string(value)
      assert byte_size(actual_path) < 80
      assert File.dir?(actual_path)
      assert (File.stat!(actual_path).mode &&& 0o777) == 0o700
    end

    test "legacy socket estimate includes workspace, repo, maximum issue and suffix" do
      workspace_root = String.duplicate("w", 50)
      length = AgentScratch.legacy_mcp_socket_path_length(workspace_root, "owner/repo")
      expected = byte_size(Path.join([workspace_root, "owner/repo", "99999", ".aiur-runtime/tmp", "aiur-mcp-9999999-999.sock"]))

      assert length == expected
      assert length > AgentScratch.mcp_socket_path_limit()
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
      absent = Aiur.TestSupport.tmp_root!("aiur-scratch-absent")

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

  test "agent temp files stay in the workspace and Codex denies direct /tmp writes", %{workspace: workspace} do
    assert CodexSandboxPolicy.default_policy(workspace)["excludeSlashTmp"]

    env =
      AgentEnvironment.workspace_env(workspace)
      |> Enum.filter(fn {name, _} -> name in [~c"TMPDIR", ~c"TMP", ~c"TEMP"] end)
      |> Enum.map(fn {name, value} -> {to_string(name), to_string(value)} end)

    {path, 0} =
      System.cmd(
        "python3",
        [
          "-c",
          "import tempfile; f = tempfile.NamedTemporaryFile(delete=False); print(f.name); f.close()"
        ],
        env: env
      )

    path = String.trim(path)
    assert Path.dirname(path) == Path.join(workspace, ".aiur-runtime/tmp")
    assert File.regular?(path)
    Aiur.TestCleanup.rm_rf!(path)
  end
end
