defmodule Aiur.DaemonHeartbeatCheckerTest do
  use ExUnit.Case, async: true

  alias Aiur.DaemonHeartbeatChecker

  describe "format_stale_message/2" do
    test "formats message when heartbeat file is missing" do
      message = DaemonHeartbeatChecker.format_stale_message(nil, nil)
      assert message =~ "not found"
      assert message =~ "may have never started"
    end

    test "formats message when age is known but threshold is not" do
      message = DaemonHeartbeatChecker.format_stale_message(7_200_000, nil)
      assert message =~ "2h0m old"
    end

    test "formats message with both age and threshold" do
      message = DaemonHeartbeatChecker.format_stale_message(7_200_000, 3_600_000)
      assert message =~ "2h0m old"
      assert message =~ "1h0m"
    end
  end

  describe "format_duration_ms/1" do
    test "formats hours and minutes" do
      assert DaemonHeartbeatChecker.format_duration_ms(5_400_000) == "1h30m"
      assert DaemonHeartbeatChecker.format_duration_ms(3_600_000) == "1h0m"
    end

    test "formats minutes and seconds" do
      assert DaemonHeartbeatChecker.format_duration_ms(125_000) == "2m5s"
      assert DaemonHeartbeatChecker.format_duration_ms(60_000) == "1m0s"
    end

    test "formats seconds only" do
      assert DaemonHeartbeatChecker.format_duration_ms(45_000) == "45s"
      assert DaemonHeartbeatChecker.format_duration_ms(1_000) == "1s"
    end

    test "formats milliseconds" do
      assert DaemonHeartbeatChecker.format_duration_ms(500) == "500ms"
      assert DaemonHeartbeatChecker.format_duration_ms(0) == "0ms"
    end

    test "handles invalid input" do
      assert DaemonHeartbeatChecker.format_duration_ms(-100) == "unknown"
      assert DaemonHeartbeatChecker.format_duration_ms(nil) == "unknown"
    end
  end

  describe "check_and_alert!/3 with dependency injection" do
    test "emits stale alert when heartbeat file is missing" do
      test_pid = self()
      path_fun = fn -> {:error, :no_such_file} end
      threshold_fun = fn -> 3_600_000 end

      emit_fun = fn topic, opts ->
        send(test_pid, {:alert, topic, opts})
        :ok
      end

      DaemonHeartbeatChecker.check_and_alert!(path_fun, threshold_fun, emit_fun)

      assert_receive {:alert, "system.daemon.stopped", opts}
      assert opts[:needs_attention] == true
      assert opts[:severity] == "critical"
      message = opts[:message]
      assert message =~ "not found"
    end

    test "emits stale alert when heartbeat is older than threshold" do
      test_pid = self()
      tmp_file = Path.join(System.tmp_dir!(), "heartbeat_#{System.unique_integer()}")

      # Write a heartbeat from 2 hours ago
      two_hours_ago = DateTime.utc_now() |> DateTime.add(-7_200, :second)
      timestamp_str = DateTime.to_iso8601(two_hours_ago)
      File.write!(tmp_file, timestamp_str <> "\n")

      on_exit(fn -> File.rm(tmp_file) end)

      path_fun = fn -> {:ok, tmp_file} end
      # 30 minutes
      threshold_fun = fn -> 1_800_000 end

      emit_fun = fn topic, opts ->
        send(test_pid, {:alert, topic, opts})
        :ok
      end

      DaemonHeartbeatChecker.check_and_alert!(path_fun, threshold_fun, emit_fun)

      assert_receive {:alert, "system.daemon.stopped", opts}
      assert opts[:needs_attention] == true
      assert opts[:severity] == "critical"
    end

    test "emits resolved alert when heartbeat is recent (within threshold)" do
      test_pid = self()
      tmp_file = Path.join(System.tmp_dir!(), "heartbeat_#{System.unique_integer()}")

      # Write a heartbeat from 1 minute ago
      one_minute_ago = DateTime.utc_now() |> DateTime.add(-60, :second)
      timestamp_str = DateTime.to_iso8601(one_minute_ago)
      File.write!(tmp_file, timestamp_str <> "\n")

      on_exit(fn -> File.rm(tmp_file) end)

      path_fun = fn -> {:ok, tmp_file} end
      # 5 minutes
      threshold_fun = fn -> 300_000 end

      emit_fun = fn topic, opts ->
        send(test_pid, {:alert, topic, opts})
        :ok
      end

      DaemonHeartbeatChecker.check_and_alert!(path_fun, threshold_fun, emit_fun)

      assert_receive {:alert, "system.daemon.stopped.resolved", opts}
      assert opts[:needs_attention] == false
      assert opts[:severity] == "info"
    end

    test "handles unparseable heartbeat file gracefully" do
      test_pid = self()
      tmp_file = Path.join(System.tmp_dir!(), "heartbeat_#{System.unique_integer()}")
      File.write!(tmp_file, "invalid timestamp\n")

      on_exit(fn -> File.rm(tmp_file) end)

      path_fun = fn -> {:ok, tmp_file} end
      threshold_fun = fn -> 3_600_000 end

      emit_fun = fn topic, opts ->
        send(test_pid, {:alert, topic, opts})
        :ok
      end

      DaemonHeartbeatChecker.check_and_alert!(path_fun, threshold_fun, emit_fun)

      assert_receive {:alert, "system.daemon.stopped", _opts}
    end

    test "handles threshold function failure gracefully" do
      tmp_file = Path.join(System.tmp_dir!(), "heartbeat_#{System.unique_integer()}")

      # Write a valid heartbeat
      now_str = DateTime.utc_now() |> DateTime.to_iso8601()
      File.write!(tmp_file, now_str <> "\n")

      on_exit(fn -> File.rm(tmp_file) end)

      path_fun = fn -> {:ok, tmp_file} end
      threshold_fun = fn -> raise "config error" end
      emit_fun = fn _topic, _opts -> :ok end

      # Should not raise; should return :ok
      assert :ok == DaemonHeartbeatChecker.check_and_alert!(path_fun, threshold_fun, emit_fun)
    end

    test "handles alert emission failure gracefully" do
      tmp_file = Path.join(System.tmp_dir!(), "heartbeat_#{System.unique_integer()}")

      # Write a stale heartbeat
      old = DateTime.utc_now() |> DateTime.add(-7_200, :second)
      File.write!(tmp_file, DateTime.to_iso8601(old) <> "\n")

      on_exit(fn -> File.rm(tmp_file) end)

      path_fun = fn -> {:ok, tmp_file} end
      threshold_fun = fn -> 3_600_000 end
      emit_fun = fn _topic, _opts -> {:error, :alert_failed} end

      # Should not raise; should return :ok despite emission failure
      assert :ok == DaemonHeartbeatChecker.check_and_alert!(path_fun, threshold_fun, emit_fun)
    end

    test "handles invalid threshold values gracefully" do
      tmp_file = Path.join(System.tmp_dir!(), "heartbeat_#{System.unique_integer()}")

      # Write a valid heartbeat
      now_str = DateTime.utc_now() |> DateTime.to_iso8601()
      File.write!(tmp_file, now_str <> "\n")

      on_exit(fn -> File.rm(tmp_file) end)

      path_fun = fn -> {:ok, tmp_file} end

      # Threshold that is not a positive integer
      threshold_fun = fn -> -100 end
      emit_fun = fn _topic, _opts -> :ok end

      # Should not raise; should return :ok
      assert :ok == DaemonHeartbeatChecker.check_and_alert!(path_fun, threshold_fun, emit_fun)
    end

    test "alert topic is system.daemon.stopped for stale alerts" do
      test_pid = self()
      path_fun = fn -> {:error, :missing} end
      threshold_fun = fn -> 3_600_000 end

      emit_fun = fn topic, _opts ->
        send(test_pid, {:topic, topic})
        :ok
      end

      DaemonHeartbeatChecker.check_and_alert!(path_fun, threshold_fun, emit_fun)

      assert_receive {:topic, "system.daemon.stopped"}
    end

    test "alert topic is system.daemon.stopped.resolved for resolved alerts" do
      test_pid = self()
      tmp_file = Path.join(System.tmp_dir!(), "heartbeat_#{System.unique_integer()}")
      fresh = DateTime.utc_now() |> DateTime.add(-10, :second)
      File.write!(tmp_file, DateTime.to_iso8601(fresh) <> "\n")

      on_exit(fn -> File.rm(tmp_file) end)

      path_fun = fn -> {:ok, tmp_file} end
      threshold_fun = fn -> 300_000 end

      emit_fun = fn topic, _opts ->
        send(test_pid, {:topic, topic})
        :ok
      end

      DaemonHeartbeatChecker.check_and_alert!(path_fun, threshold_fun, emit_fun)

      assert_receive {:topic, "system.daemon.stopped.resolved"}
    end

    test "does not emit alert when heartbeat is very close to threshold boundary" do
      test_pid = self()
      tmp_file = Path.join(System.tmp_dir!(), "heartbeat_#{System.unique_integer()}")

      # Write a heartbeat exactly at threshold (e.g., 3599s ago for 3600s threshold)
      # Should use resolved alert, not stale alert
      threshold_ms = 3_600_000
      just_within = DateTime.utc_now() |> DateTime.add(-3_599, :second)
      File.write!(tmp_file, DateTime.to_iso8601(just_within) <> "\n")

      on_exit(fn -> File.rm(tmp_file) end)

      path_fun = fn -> {:ok, tmp_file} end
      threshold_fun = fn -> threshold_ms end

      emit_fun = fn topic, _opts ->
        send(test_pid, {:topic, topic})
        :ok
      end

      DaemonHeartbeatChecker.check_and_alert!(path_fun, threshold_fun, emit_fun)

      assert_receive {:topic, "system.daemon.stopped.resolved"}
    end

    test "emits stale alert when heartbeat exceeds threshold boundary" do
      test_pid = self()
      tmp_file = Path.join(System.tmp_dir!(), "heartbeat_#{System.unique_integer()}")

      # Write a heartbeat just over threshold (e.g., 3601s ago for 3600s threshold)
      threshold_ms = 3_600_000
      just_over = DateTime.utc_now() |> DateTime.add(-3_601, :second)
      File.write!(tmp_file, DateTime.to_iso8601(just_over) <> "\n")

      on_exit(fn -> File.rm(tmp_file) end)

      path_fun = fn -> {:ok, tmp_file} end
      threshold_fun = fn -> threshold_ms end

      emit_fun = fn topic, _opts ->
        send(test_pid, {:topic, topic})
        :ok
      end

      DaemonHeartbeatChecker.check_and_alert!(path_fun, threshold_fun, emit_fun)

      assert_receive {:topic, "system.daemon.stopped"}
    end
  end
end
