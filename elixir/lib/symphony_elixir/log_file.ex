defmodule SymphonyElixir.LogFile do
  @moduledoc """
  Configures OTP's built-in rotating disk log handler for application logs.
  """

  require Logger

  @handler_id :symphony_disk_log
  @default_log_relative_path "log/symphony.log"
  @default_max_bytes 10 * 1024 * 1024
  @default_max_files 5

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
    max_bytes = Application.get_env(:symphony_elixir, :log_file_max_bytes, @default_max_bytes)
    max_files = Application.get_env(:symphony_elixir, :log_file_max_files, @default_max_files)

    setup_disk_handler(log_file, max_bytes, max_files)
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

  defp setup_disk_handler(log_file, max_bytes, max_files) do
    expanded_path = Path.expand(log_file)
    :ok = File.mkdir_p(Path.dirname(expanded_path))
    :ok = remove_existing_handler()

    case :logger.add_handler(
           @handler_id,
           :logger_disk_log_h,
           disk_log_handler_config(expanded_path, max_bytes, max_files)
         ) do
      :ok ->
        remove_default_console_handler()
        :ok

      {:error, reason} ->
        Logger.warning("Failed to configure rotating log file handler: #{inspect(reason)}")
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

  defp disk_log_handler_config(path, max_bytes, max_files) do
    %{
      level: :all,
      formatter: {:logger_formatter, %{single_line: true}},
      config: %{
        file: String.to_charlist(path),
        type: :wrap,
        max_no_bytes: max_bytes,
        max_no_files: max_files
      }
    }
  end
end
