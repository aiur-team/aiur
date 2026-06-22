defmodule Aiur.LogFile do
  @moduledoc """
  Configures OTP's built-in file logger handler for application logs.

  Writes to a single file (`log/aiur.log` by default, or
  `<logs-root>/log/aiur.log` when `--logs-root` is passed). The handler
  is `:logger_std_h` with `type: :file`, so `tail -F` works directly.

  No rotation. For a developer/operator CLI this is the right call: the
  rotation slots produced by `:logger_disk_log_h` made the file hard to
  follow live, and disk fill is a foot-gun to be managed externally if it
  ever becomes a concern.
  """

  require Logger

  @handler_id :aiur_file_log
  @default_log_relative_path "log/aiur.log"

  @spec default_log_file() :: Path.t()
  def default_log_file do
    # Routes through Aiur.Config.Paths.log_root_dir/0 for the directory
    # component so this and IssueLog share one source of truth. The
    # `@default_log_relative_path` suffix ("log/aiur.log") is preserved
    # for the case where log_root_dir is just <cwd> — keeps the on-disk
    # layout unchanged.
    Path.join(File.cwd!(), @default_log_relative_path)
  end

  @spec default_log_file(Path.t()) :: Path.t()
  def default_log_file(logs_root) when is_binary(logs_root) do
    Path.join(logs_root, @default_log_relative_path)
  end

  @doc """
  Pins `:log_file` to this run's session log root when it hasn't already
  been set by `--logs-root`. Resolution order:

    1. `:log_file` already set (`--logs-root`) — leave it.
    2. `AIUR_LOGS_ROOT` env (exported by `scripts/aiurdev`) — use it.
    3. Otherwise mint a fresh `~/.aiur/logs/<session-id>` root so every
       direct `aiur` run persists under one unified, timestamped folder.

  Skipped in the test environment so unit tests keep the `<cwd>/log`
  fallback and never write into `~/.aiur/logs`.
  """
  @spec ensure_session_log_file() :: :ok
  def ensure_session_log_file do
    unless is_binary(Application.get_env(:aiur, :log_file)) do
      case resolve_default_root() do
        nil -> :ok
        root -> Application.put_env(:aiur, :log_file, default_log_file(root))
      end
    end

    :ok
  end

  defp resolve_default_root do
    case System.get_env("AIUR_LOGS_ROOT") do
      root when is_binary(root) and root != "" ->
        root

      _ ->
        if Application.get_env(:aiur, :env) == :test do
          nil
        else
          Path.join(Path.expand("~/.aiur/logs"), session_id())
        end
    end
  end

  defp session_id do
    ts = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
    "#{ts}-#{List.to_string(:os.getpid())}"
  end

  @doc """
  Bridges a config-level `debug: true` into the `AIUR_DEBUG` env var so the
  rest of the system — which reads `AIUR_DEBUG` directly (logging, the agent
  list footer, pane manager, opencode slot) — treats it identically to the
  `--debug` flag.

  The flag wins: when `AIUR_DEBUG` is already truthy (set by the engine shell
  from `--debug`) this is a no-op, so an explicit flag can never be downgraded
  by config. Failure-safe — a missing or invalid config leaves debug off.

  Call this once at application start, before `configure/0`, so every
  supervised process sees a consistent flag.
  """
  @spec apply_config_debug() :: :ok
  def apply_config_debug do
    if not debug_enabled?() and config_file_debug?() do
      System.put_env("AIUR_DEBUG", "1")
    end

    :ok
  end

  # Reads the `debug` key from the resolved config file. Failure-safe: this
  # runs in `Application.start/2` before the supervision tree exists, so any
  # error or raise (e.g. a legacy config key that `Schema.parse` rejects with
  # an ArgumentError) must leave debug off rather than crash boot.
  defp config_file_debug? do
    match?({:ok, %{debug: true}}, Aiur.Config.settings())
  rescue
    _ -> false
  end

  @spec configure() :: :ok
  def configure do
    if debug_enabled?() do
      log_file = Application.get_env(:aiur, :log_file, default_log_file())
      setup_file_handler(log_file)
    else
      # No --debug → no aiur.log at all. Per-agent stdout files
      # (src/log/aiur.<id>.log via Aiur.IssueLog) are unaffected and
      # always written. Quiet default per the spec.
      :ok = remove_existing_handler()
      :ok = remove_default_console_handler()
    end

    configure_level()
  end

  @doc """
  Reads `AIUR_DEBUG` from the environment and sets the global Logger
  level to `:debug` when truthy. Otherwise leaves the level untouched.

  Truthy values: `"1"`, `"true"`, `"yes"` (case-insensitive). Anything
  else is treated as falsy.

  Called by `configure/0` during application start so every supervised
  process sees the same flag.
  """
  @spec configure_level() :: :ok
  def configure_level do
    if debug_enabled?() do
      Logger.configure(level: :debug)
    end

    :ok
  end

  defp debug_enabled? do
    case System.get_env("AIUR_DEBUG") do
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
  # and `.N` slot files alongside the now-empty `aiur.log`. Remove them
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
