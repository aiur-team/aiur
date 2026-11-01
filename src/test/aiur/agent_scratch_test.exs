defmodule Aiur.AgentScratchTest do
  import Bitwise
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

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
      {uid, 0} = System.cmd("id", ["-u"])
      runtime_root = Path.join("/tmp", "aiur-scratch-#{System.unique_integer([:positive])}")
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(runtime_root) end)
      opts = [runtime_root: runtime_root, user_id: String.trim(uid)]
      path = AgentScratch.mcp_socket_dir(workspace, opts)
      assert byte_size(path) < 80
      assert path == AgentScratch.mcp_socket_dir(workspace, opts)
      assert [{~c"AIUR_MCP_SOCKET_DIR", value}] = AgentScratch.mcp_socket_env(workspace, opts)
      actual_path = to_string(value)
      assert byte_size(actual_path) < 80
      assert byte_size(Path.join(actual_path, "aiur-mcp-9999999-999.sock")) <= 100
      assert File.dir?(actual_path)
      assert (File.stat!(actual_path).mode &&& 0o777) == 0o700
    end

    test "falls back from an overlong runtime directory", %{workspace: workspace} do
      path = AgentScratch.mcp_socket_dir(workspace, runtime_root: "/#{String.duplicate("r", 120)}", user_id: "1234567890")

      assert path =~ "/tmp/aiur-1234567890/"
      assert byte_size(Path.join(path, "aiur-mcp-9999999-999.sock")) <= 100
    end

    test "legacy socket estimate includes workspace, repo, maximum issue and suffix" do
      workspace_root = String.duplicate("w", 50)
      length = AgentScratch.legacy_mcp_socket_path_length(workspace_root, "owner/repo")
      workspace = Path.join([workspace_root, "owner", "repo", "99999"])
      expected = byte_size(Path.join([workspace, ".aiur-runtime/tmp", "aiur-mcp-9999999-999.sock"]))

      assert length == expected
      assert length > AgentScratch.mcp_socket_path_limit()
    end

    test "removes the workspace's private MCP socket directory", %{workspace: workspace} do
      assert [{~c"AIUR_MCP_SOCKET_DIR", path}] = AgentScratch.mcp_socket_env(workspace)
      socket_dir = List.to_string(path)
      assert File.dir?(socket_dir)

      assert :ok = AgentScratch.remove_mcp_socket_dir(workspace)
      refute File.exists?(socket_dir)
    end

    test "warning reports the maximum legacy path but ignores a short configured socket path" do
      workspace = Path.join(["/root", String.duplicate("w", 70), "owner", "repo", "17"])
      expected_length = byte_size(Path.join(["/root", String.duplicate("w", 70), "owner", "repo", "99999", ".aiur-runtime/tmp", "aiur-mcp-9999999-999.sock"]))

      log = capture_log(fn -> AgentScratch.warn_mcp_socket_path(workspace, []) end)
      assert log =~ "#{expected_length} bytes > 107"

      short_dir = "/tmp/aiur-short"
      short_env = [{~c"AIUR_MCP_SOCKET_DIR", String.to_charlist(short_dir)}]
      short_workspace = Path.join(["/root", String.duplicate("w", 70), "owner", "other", "17"])

      refute capture_log(fn -> AgentScratch.warn_mcp_socket_path(short_workspace, short_env) end) =~
               "Claude MCP bridge socket path may exceed"
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
