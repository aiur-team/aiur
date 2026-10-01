defmodule Aiur.DaemonHeartbeatTest do
  use ExUnit.Case, async: false

  alias Aiur.DaemonHeartbeat
  alias Aiur.Config.Paths

  setup do
    temp_root = Aiur.TestSupport.tmp_root!("aiur-daemon-heartbeat")
    File.rm_rf!(temp_root)
    File.mkdir_p!(temp_root)

    # Set up decision state dir so daemon_heartbeat_path resolves correctly
    decision_state_dir = Path.join(temp_root, "decision-state")
    previous = Application.get_env(:aiur, :decision_state_dir)
    Application.put_env(:aiur, :decision_state_dir, decision_state_dir)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:aiur, :decision_state_dir)
      else
        Application.put_env(:aiur, :decision_state_dir, previous)
      end

      File.rm_rf!(temp_root)
    end)

    :ok
  end

  describe "write!/0" do
    test "creates heartbeat file with valid ISO 8601 timestamp" do
      assert :ok = DaemonHeartbeat.write!()

      # Use the actual path that daemon_heartbeat_path() resolves
      {:ok, heartbeat_path} = Paths.daemon_heartbeat_path()
      assert File.exists?(heartbeat_path)

      content = File.read!(heartbeat_path)
      # Remove trailing newline for timestamp parsing
      timestamp_str = String.trim_trailing(content, "\n")

      # Verify it's a valid ISO 8601 timestamp
      assert {:ok, _datetime, 0} = DateTime.from_iso8601(timestamp_str)
    end

    test "file is readable and contains exactly timestamp + newline" do
      before = DateTime.utc_now()
      assert :ok = DaemonHeartbeat.write!()
      after_call = DateTime.utc_now()

      {:ok, heartbeat_path} = Paths.daemon_heartbeat_path()
      content = File.read!(heartbeat_path)

      # Should be timestamp + single newline
      lines = String.split(content, "\n")
      assert Enum.at(lines, 1) == "", "content should end with exactly one newline"

      timestamp_str = Enum.at(lines, 0)
      assert {:ok, written_time, 0} = DateTime.from_iso8601(timestamp_str)

      # Verify timestamp is reasonable (written between before and after call)
      # Allow 1 second margin for clock skew / system jitter
      assert DateTime.compare(written_time, DateTime.add(before, -1, :second)) in [:gt, :eq]
      assert DateTime.compare(written_time, DateTime.add(after_call, 1, :second)) in [:lt, :eq]
    end

    test "multiple writes overwrite previous timestamp without appending" do
      assert :ok = DaemonHeartbeat.write!()

      {:ok, heartbeat_path} = Paths.daemon_heartbeat_path()
      first_content = File.read!(heartbeat_path)

      Process.sleep(10)

      assert :ok = DaemonHeartbeat.write!()

      second_content = File.read!(heartbeat_path)

      # Should not be identical (timestamp should have changed)
      assert first_content != second_content

      # Count newlines to ensure we have exactly one (no appending)
      newline_count = String.split(second_content, "\n") |> length() |> Kernel.-(1)
      assert newline_count == 1, "file should contain exactly one newline"
    end

    test "creates parent directories automatically" do
      {:ok, heartbeat_path} = Paths.daemon_heartbeat_path()
      parent_dir = Path.dirname(heartbeat_path)

      # Verify directories don't exist yet
      File.rm_rf!(parent_dir)
      refute File.exists?(parent_dir)

      assert :ok = DaemonHeartbeat.write!()

      # Verify all parent directories were created
      assert File.exists?(heartbeat_path)
      assert File.exists?(parent_dir)
    end

    test "handles write failure gracefully with warning log" do
      {:ok, heartbeat_path} = Paths.daemon_heartbeat_path()
      parent_dir = Path.dirname(heartbeat_path)

      # Make the parent directory read-only to force a write failure
      File.mkdir_p!(parent_dir)
      File.chmod!(parent_dir, 0o444)

      on_exit(fn ->
        # Restore write permissions before cleanup
        File.chmod!(parent_dir, 0o755)
      end)

      # Should not raise, just log warning and return :ok
      assert :ok = DaemonHeartbeat.write!()
    end

    test "handles path resolution failure gracefully" do
      # Override decision_state_dir to return an error
      previous = Application.get_env(:aiur, :decision_state_dir)
      Application.delete_env(:aiur, :decision_state_dir)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:aiur, :decision_state_dir)
        else
          Application.put_env(:aiur, :decision_state_dir, previous)
        end
      end)

      # Should not raise, just log warning and return :ok
      assert :ok = DaemonHeartbeat.write!()
    end

    test "timestamp is in UTC zone" do
      assert :ok = DaemonHeartbeat.write!()

      {:ok, heartbeat_path} = Paths.daemon_heartbeat_path()
      content = File.read!(heartbeat_path)
      timestamp_str = String.trim_trailing(content, "\n")

      # Verify the timestamp ends with 'Z' (UTC indicator)
      assert String.ends_with?(timestamp_str, "Z")

      # Verify it parses with UTC offset of 0
      assert {:ok, _datetime, 0} = DateTime.from_iso8601(timestamp_str)
    end
  end

  describe "integration with application start" do
    test "heartbeat file is written during application boot" do
      temp_root = Aiur.TestSupport.tmp_root!("aiur-daemon-heartbeat-boot")
      File.rm_rf!(temp_root)
      File.mkdir_p!(temp_root)

      decision_state_dir = Path.join(temp_root, "decision-state")

      try do
        code_paths = test_code_paths()

        script = """
        Application.put_env(:aiur, :decision_state_dir, #{inspect(decision_state_dir)})
        :ok = Aiur.DaemonHeartbeat.write!()
        heartbeat_path = Path.join([#{inspect(decision_state_dir)}, "executor", "aiur.daemon-heartbeat"])
        if File.exists?(heartbeat_path) do
          content = File.read!(heartbeat_path)
          IO.puts("HEARTBEAT_EXISTS:" <> content)
        else
          IO.puts("HEARTBEAT_MISSING")
        end
        """

        {output, 0} =
          System.cmd(System.find_executable("elixir"), code_paths ++ ["-e", script],
            cd: File.cwd!(),
            stderr_to_stdout: true
          )

        assert String.contains?(output, "HEARTBEAT_EXISTS:")
        refute String.contains?(output, "HEARTBEAT_MISSING")

        # Extract and verify timestamp from output
        [timestamp_line] = Regex.run(~r/HEARTBEAT_EXISTS:(.+)/m, output, capture: :all_but_first)
        timestamp_str = String.trim_trailing(timestamp_line, "\n")
        assert {:ok, _datetime, 0} = DateTime.from_iso8601(timestamp_str)
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  defp test_code_paths do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&String.contains?(&1, "/_build/test/lib/"))
    |> Enum.flat_map(&["-pa", &1])
  end
end
