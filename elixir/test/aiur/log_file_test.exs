defmodule Aiur.LogFileTest do
  use ExUnit.Case, async: false

  alias Aiur.LogFile

  test "default_log_file/0 uses the current working directory" do
    assert LogFile.default_log_file() == Path.join(File.cwd!(), "log/aiur.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/aiur-logs") == "/tmp/aiur-logs/log/aiur.log"
  end

  describe "configure/0" do
    setup do
      # Snapshot + restore: this test reshapes the global :logger
      # config and other tests in the suite assume the application's
      # default handlers stay in place.
      original_default =
        case :logger.get_handler_config(:default) do
          {:ok, config} -> {:installed, config}
          {:error, _} -> :absent
        end

      original_aiur =
        case :logger.get_handler_config(:aiur_file_log) do
          {:ok, config} -> {:installed, config}
          {:error, _} -> :absent
        end

      original_env = Application.get_env(:aiur, :log_file)

      tmp_root = Path.join(System.tmp_dir!(), "aiur-logfile-test-#{System.unique_integer([:positive])}")
      log_file = Path.join(tmp_root, "log/aiur.log")
      Application.put_env(:aiur, :log_file, log_file)

      on_exit(fn ->
        :logger.remove_handler(:aiur_file_log)

        case original_aiur do
          {:installed, %{module: module} = config} ->
            :logger.add_handler(:aiur_file_log, module, Map.drop(config, [:id]))

          :absent ->
            :ok
        end

        case original_default do
          {:installed, %{module: module} = config} ->
            _ = :logger.remove_handler(:default)
            :logger.add_handler(:default, module, Map.drop(config, [:id]))

          :absent ->
            :ok
        end

        case original_env do
          nil -> Application.delete_env(:aiur, :log_file)
          value -> Application.put_env(:aiur, :log_file, value)
        end

        File.rm_rf!(tmp_root)
      end)

      %{log_file: log_file}
    end

    test "removes the default console handler so logs do not flash on stdout", %{log_file: log_file} do
      # Regression: pane BEAMs only called configure_level/0, so their
      # default console handler stayed wired up and every Logger.debug
      # at bootstrap flashed onto the operator's terminal for a beat
      # before the conversation pane took over the screen.
      assert :ok = LogFile.configure()

      assert {:error, {:not_found, :default}} = :logger.get_handler_config(:default)
      assert {:ok, %{id: :aiur_file_log}} = :logger.get_handler_config(:aiur_file_log)
      assert File.exists?(Path.dirname(log_file))
    end
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
