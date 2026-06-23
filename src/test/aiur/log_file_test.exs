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
      # File handler is only installed when AIUR_DEBUG is on (the
      # default `aiur` invocation stays quiet); the console removal
      # behavior holds in both modes.
      System.put_env("AIUR_DEBUG", "1")
      on_exit(fn -> System.delete_env("AIUR_DEBUG") end)

      assert :ok = LogFile.configure()

      assert {:error, {:not_found, :default}} = :logger.get_handler_config(:default)
      assert {:ok, %{id: :aiur_file_log}} = :logger.get_handler_config(:aiur_file_log)
      assert File.exists?(Path.dirname(log_file))
    end
  end

  describe "ensure_session_log_file/0" do
    setup do
      original_env = Application.get_env(:aiur, :log_file)
      original_root = System.get_env("AIUR_LOGS_ROOT")

      on_exit(fn ->
        case original_env do
          nil -> Application.delete_env(:aiur, :log_file)
          value -> Application.put_env(:aiur, :log_file, value)
        end

        case original_root do
          nil -> System.delete_env("AIUR_LOGS_ROOT")
          value -> System.put_env("AIUR_LOGS_ROOT", value)
        end
      end)

      :ok
    end

    test "pins :log_file under AIUR_LOGS_ROOT when not already set" do
      Application.delete_env(:aiur, :log_file)
      System.put_env("AIUR_LOGS_ROOT", "/tmp/aiur-session-xyz")

      assert :ok = LogFile.ensure_session_log_file()
      assert Application.get_env(:aiur, :log_file) == "/tmp/aiur-session-xyz/log/aiur.log"
    end

    test "leaves an explicit :log_file (from --logs-root) untouched" do
      # --logs-root resolves before boot; the session default must not
      # clobber an operator-chosen path.
      Application.put_env(:aiur, :log_file, "/custom/path/log/aiur.log")
      System.put_env("AIUR_LOGS_ROOT", "/tmp/should-be-ignored")

      assert :ok = LogFile.ensure_session_log_file()
      assert Application.get_env(:aiur, :log_file) == "/custom/path/log/aiur.log"
    end

    test "never mints a ~/.aiur/logs root in the test environment" do
      # Safety: unit tests must not write into the operator's real
      # ~/.aiur/logs. With no override the test env keeps :log_file unset
      # (Paths then falls back to <cwd>/log).
      Application.delete_env(:aiur, :log_file)
      System.delete_env("AIUR_LOGS_ROOT")

      assert :ok = LogFile.ensure_session_log_file()
      assert Application.get_env(:aiur, :log_file) == nil
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

  describe "apply_config_debug/0" do
    setup do
      original_debug = System.get_env("AIUR_DEBUG")
      original_path = Application.get_env(:aiur, :workflow_file_path)
      System.delete_env("AIUR_DEBUG")

      dir = Path.join(System.tmp_dir!(), "aiur-config-debug-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      on_exit(fn ->
        File.rm_rf!(dir)

        case original_path do
          nil -> Aiur.Workflow.clear_workflow_file_path()
          path -> Aiur.Workflow.set_workflow_file_path(path)
        end

        case original_debug do
          nil -> System.delete_env("AIUR_DEBUG")
          value -> System.put_env("AIUR_DEBUG", value)
        end
      end)

      %{dir: dir}
    end

    defp write_config!(dir, body) do
      path = Path.join(dir, "config")
      File.write!(path, body)
      Aiur.Workflow.set_workflow_file_path(path)
    end

    test "sets AIUR_DEBUG when config debug: true and the flag is unset", %{dir: dir} do
      write_config!(dir, "tracker:\n  kind: memory\ndebug: true\n")

      assert :ok = LogFile.apply_config_debug()
      assert System.get_env("AIUR_DEBUG") == "1"
    end

    test "leaves AIUR_DEBUG unset when config debug: false", %{dir: dir} do
      write_config!(dir, "tracker:\n  kind: memory\ndebug: false\n")

      assert :ok = LogFile.apply_config_debug()
      assert System.get_env("AIUR_DEBUG") == nil
    end

    test "leaves AIUR_DEBUG unset when the debug key is absent", %{dir: dir} do
      write_config!(dir, "tracker:\n  kind: memory\n")

      assert :ok = LogFile.apply_config_debug()
      assert System.get_env("AIUR_DEBUG") == nil
    end

    test "does not override an already-enabled AIUR_DEBUG (flag wins)", %{dir: dir} do
      # The engine shell sets AIUR_DEBUG=1 from --debug before boot; config
      # must never clobber it, even with a conflicting debug: false.
      System.put_env("AIUR_DEBUG", "true")
      write_config!(dir, "tracker:\n  kind: memory\ndebug: false\n")

      assert :ok = LogFile.apply_config_debug()
      assert System.get_env("AIUR_DEBUG") == "true"
    end

    test "preserves a truthy-alias flag verbatim even when config also wants debug", %{dir: dir} do
      # When the flag is already on, config must be a no-op — it must not
      # normalize the operator's flag value (e.g. "true" -> "1").
      System.put_env("AIUR_DEBUG", "true")
      write_config!(dir, "tracker:\n  kind: memory\ndebug: true\n")

      assert :ok = LogFile.apply_config_debug()
      assert System.get_env("AIUR_DEBUG") == "true"
    end

    test "is failure-safe when the config cannot be read", %{dir: dir} do
      Aiur.Workflow.set_workflow_file_path(Path.join(dir, "does-not-exist"))

      assert :ok = LogFile.apply_config_debug()
      assert System.get_env("AIUR_DEBUG") == nil
    end

    test "is failure-safe when the config raises during schema validation", %{dir: dir} do
      # A legacy `polling.interval_ms` key makes Schema.parse raise; the boot
      # bridge must swallow it and leave debug off rather than crash start/2.
      write_config!(dir, "tracker:\n  kind: memory\npolling:\n  interval_ms: 1000\ndebug: true\n")

      assert :ok = LogFile.apply_config_debug()
      assert System.get_env("AIUR_DEBUG") == nil
    end
  end
end
