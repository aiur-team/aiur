defmodule Aiur.LogFileTest do
  use ExUnit.Case, async: false

  alias Aiur.LogFile

  test "default_log_file/0 uses the current working directory" do
    assert LogFile.default_log_file() == Path.join(File.cwd!(), "log/aiur.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/aiur-logs") == "/tmp/aiur-logs/log/aiur.log"
  end

  describe "configure_level/0" do
    setup do
      original = Logger.level()
      original_env = System.get_env("AIUR_DEBUG")

      on_exit(fn ->
        Logger.configure(level: original)

        case original_env do
          nil -> System.delete_env("AIUR_DEBUG")
          value -> System.put_env("AIUR_DEBUG", value)
        end
      end)

      :ok
    end

    test "sets debug level when AIUR_DEBUG=1" do
      Logger.configure(level: :info)
      System.put_env("AIUR_DEBUG", "1")

      assert :ok = LogFile.configure_level()
      assert Logger.level() == :debug
    end

    test "sets debug level for truthy aliases" do
      for value <- ["true", "YES", " true ", "Yes"] do
        Logger.configure(level: :info)
        System.put_env("AIUR_DEBUG", value)
        assert :ok = LogFile.configure_level()
        assert Logger.level() == :debug, "expected :debug for #{inspect(value)}"
      end
    end

    test "leaves level unchanged when AIUR_DEBUG is unset" do
      Logger.configure(level: :info)
      System.delete_env("AIUR_DEBUG")

      assert :ok = LogFile.configure_level()
      assert Logger.level() == :info
    end

    test "leaves level unchanged for falsy values" do
      Logger.configure(level: :info)

      for value <- ["0", "false", "", "no"] do
        System.put_env("AIUR_DEBUG", value)
        assert :ok = LogFile.configure_level()
        assert Logger.level() == :info, "expected :info to stay for #{inspect(value)}"
      end
    end
  end
end
