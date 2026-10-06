defmodule Aiur.Config.PathsHeartbeatTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.Paths

  describe "daemon_heartbeat_path/0" do
    setup do
      original_override = Application.get_env(:aiur, :decision_state_dir)

      on_exit(fn ->
        case original_override do
          nil -> Application.delete_env(:aiur, :decision_state_dir)
          value -> Application.put_env(:aiur, :decision_state_dir, value)
        end
      end)

      :ok
    end

    test "returns a valid path under the decision state directory" do
      Application.put_env(:aiur, :decision_state_dir, "/tmp/aiur-private-state")

      assert {:ok, path} = Paths.daemon_heartbeat_path()
      assert String.starts_with?(path, "/tmp/aiur-private-state")
    end

    test "includes the executor subdirectory" do
      Application.put_env(:aiur, :decision_state_dir, "/tmp/aiur-private-state")

      assert {:ok, path} = Paths.daemon_heartbeat_path()
      assert String.contains?(path, "/executor/")
    end

    test "includes the repo name in the filename" do
      Application.put_env(:aiur, :decision_state_dir, "/tmp/aiur-private-state")

      assert {:ok, path} = Paths.daemon_heartbeat_path()
      repo_name = Paths.repo_name()
      assert String.ends_with?(path, "#{repo_name}.daemon-heartbeat")
    end

    test "returns consistent path across repeated calls" do
      Application.put_env(:aiur, :decision_state_dir, "/tmp/aiur-private-state")

      assert {:ok, path1} = Paths.daemon_heartbeat_path()
      assert {:ok, path2} = Paths.daemon_heartbeat_path()

      assert path1 == path2
    end

    test "returns an error when decision_state_dir is missing or invalid" do
      Application.delete_env(:aiur, :decision_state_dir)
      System.delete_env("AIUR_INSTANCE_KEY")

      assert {:error, :missing_instance_key} = Paths.daemon_heartbeat_path()
    end

    test "returns absolute path" do
      Application.put_env(:aiur, :decision_state_dir, "/tmp/aiur-private-state")

      assert {:ok, path} = Paths.daemon_heartbeat_path()
      assert Path.absname(path) == path
    end
  end
end
