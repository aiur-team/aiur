defmodule SymphonyElixir.LogFile do
  @moduledoc """
  Configures OTP's built-in file logger handler for application logs.

  Writes to a single file (`log/symphony.log` by default, or
  `<logs-root>/log/symphony.log` when `--logs-root` is passed). The handler
  is `:logger_std_h` with `type: :file`, so `tail -F` works directly.

  No rotation. For a developer/operator CLI this is the right call: the
  rotation slots produced by `:logger_disk_log_h` made the file hard to
  follow live, and disk fill is a foot-gun to be managed externally if it
  ever becomes a concern.
  """

  require Logger

  @handler_id :symphony_file_log
  @default_log_relative_path "log/symphony.log"

  @spec default_log_file() :: Path.t()
  def default_log_file do
    default_log_file(File.cwd!())
  end

  @spec default_log_file(Path.t()) :: Path.t()
  def default_log_file(logs_root) when is_binary(logs_root) do
    Path.join(logs_root, @default_log_relative_path)
  end

  @spec configure() :: :ok
  def configure do
    log_file = Application.get_env(:symphony_elixir, :log_file, default_log_file())

    setup_file_handler(log_file)
    configure_level()
  end

  @doc """
  Reads `SYMPHONY_DEBUG` from the environment and sets the global Logger
  level to `:debug` when truthy. Otherwise leaves the level untouched.

  Truthy values: `"1"`, `"true"`, `"yes"` (case-insensitive). Anything
  else is treated as falsy.

  Called by `configure/0` during application start and by
  `SymphonyPane.CLI.main/1` during pane bootstrap so both BEAMs see the
  same flag.
  """
  @spec configure_level() :: :ok
  def configure_level do
    if debug_enabled?() do
      Logger.configure(level: :debug)
    end

    :ok
  end

  defp debug_enabled? do
    case System.get_env("SYMPHONY_DEBUG") do
      value when is_binary(value) ->
        String.downcase(String.trim(value)) in ["1", "true", "yes"]

      _ ->
        false
    end
  end

  defp setup_file_handler(log_file) do
    expanded_path = Path.expand(log_file)
    :ok = File.mkdir_p(Path.dirname(expanded_path))
    :ok = remove_existing_handler()
    :ok = remove_legacy_wrap_files(expanded_path)

    case :logger.add_handler(@handler_id, :logger_std_h, file_handler_config(expanded_path)) do
      :ok ->
        remove_default_console_handler()
        :ok

      {:error, reason} ->
        Logger.warning("Failed to configure file log handler: #{inspect(reason)}")
        :ok
    end
  end

  # Old runs that used the disk_log/wrap handler leave behind `.idx`, `.siz`,
  # and `.N` slot files alongside the now-empty `symphony.log`. Remove them
  # so the directory listing is unambiguous when the user tails the file.
  defp remove_legacy_wrap_files(path) do
    base = Path.basename(path)
    dir = Path.dirname(path)

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry ->
          entry == base <> ".idx" or entry == base <> ".siz" or
            String.match?(entry, ~r/^#{Regex.escape(base)}\.\d+$/)
        end)
        |> Enum.each(fn entry -> File.rm(Path.join(dir, entry)) end)

        :ok

      _ ->
        :ok
    end
  end

  defp remove_existing_handler do
    case :logger.remove_handler(@handler_id) do
      :ok -> :ok
      {:error, {:not_found, @handler_id}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp remove_default_console_handler do
    case :logger.remove_handler(:default) do
      :ok -> :ok
      {:error, {:not_found, :default}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp file_handler_config(path) do
    %{
      level: :all,
      formatter: {:logger_formatter, %{single_line: true}},
      config: %{
        file: String.to_charlist(path),
        type: :file,
        # Sync to disk frequently so `tail -F` sees output without the
        # default ~1s buffer.
        filesync_repeat_interval: 200
      }
    }
  end
end
