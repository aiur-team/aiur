defmodule Aiur.Codex.AppServerPortTest do
  use Aiur.TestSupport, async: false

  alias Aiur.AppServer.Adapter
  alias Aiur.Codex.AppServerPort
  alias Aiur.Codex.Config, as: CodexConfig

  describe "validate_workspace_cwd/2 local" do
    test "accepts a genuine sub-path and rejects the workspace root" do
      root = Config.workspace_root()
      File.mkdir_p!(Path.join(root, "issue-1"))

      assert {:ok, accepted} = AppServerPort.validate_workspace_cwd(Path.join(root, "issue-1"), nil)
      assert accepted == Path.join(root, "issue-1")

      assert {:error, {:invalid_workspace_cwd, :workspace_root, ^root}} =
               AppServerPort.validate_workspace_cwd(root, nil)
    end

    test "rejects paths outside the workspace root and symlink escapes" do
      root = Config.workspace_root()
      outside = Path.join(System.tmp_dir!(), "aiur-outside-#{System.unique_integer([:positive])}")
      linked = Path.join(root, "linked-out")

      File.mkdir_p!(root)
      File.mkdir_p!(outside)
      File.rm(linked)
      File.ln_s!(outside, linked)

      on_exit(fn ->
        File.rm(linked)
        File.rm_rf(outside)
      end)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _, _}} =
               AppServerPort.validate_workspace_cwd(outside, nil)

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^linked, _}} =
               AppServerPort.validate_workspace_cwd(linked, nil)
    end
  end

  describe "validate_workspace_cwd/2 remote" do
    test "rejects empty and control-character remote paths" do
      assert {:error, {:invalid_workspace_cwd, :empty_remote_workspace, "host"}} =
               AppServerPort.validate_workspace_cwd(" ", "host")

      for workspace <- ["repo\npath", "repo\rpath", "repo" <> <<0>> <> "path"] do
        assert {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, "host", ^workspace}} =
                 AppServerPort.validate_workspace_cwd(workspace, "host")
      end
    end
  end

  describe "codex command test seam" do
    test "nil model leaves the configured command untouched" do
      assert AppServerPort.codex_command_for_test(nil) == CodexConfig.command()
    end

    test "appends model then effort with shell escaping" do
      command = AppServerPort.codex_command_for_test("gpt'5.5", "high")

      assert command ==
               CodexConfig.command() <>
                 " --config 'model=\"gpt'\"'\"'5.5\"' --config 'model_reasoning_effort=\"high\"'"
    end
  end

  describe "port_metadata/2" do
    test "includes the app-server os pid and remote worker host when present" do
      port = open_cat_port()
      metadata = AppServerPort.port_metadata(port, "worker-1")

      assert is_binary(metadata.codex_app_server_pid)
      assert metadata.worker_host == "worker-1"

      Port.close(port)
    end

    test "omits worker_host for local ports" do
      port = open_cat_port()
      metadata = AppServerPort.port_metadata(port)

      assert is_binary(metadata.codex_app_server_pid)
      refute Map.has_key?(metadata, :worker_host)

      Port.close(port)
    end

    test "records a local process group only when the port root is its leader" do
      if System.find_executable("setsid") do
        assert {:ok, port} = Adapter.start_port(File.cwd!(), "printf 'ready\\n'; sleep 600")

        try do
          assert_receive {^port, {:data, {:eol, "ready"}}}, 1_000

          metadata = AppServerPort.port_metadata(port)

          assert metadata.agent_process_group_id == metadata.codex_app_server_pid
        after
          AppServerPort.stop_port(port)
        end
      else
        assert true
      end
    end
  end

  describe "stop_port/1" do
    test "returns :ok for an already closed port" do
      port = open_cat_port()
      true = Port.close(port)

      assert :ok = AppServerPort.stop_port(port)
    end
  end

  defp open_cat_port do
    Port.open({:spawn_executable, String.to_charlist(System.find_executable("cat"))}, [
      :binary,
      :exit_status
    ])
  end
end
