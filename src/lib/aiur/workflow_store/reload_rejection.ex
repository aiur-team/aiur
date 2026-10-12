defmodule Aiur.WorkflowStore.ReloadRejection do
  @moduledoc """
  Validates a hot-reloaded config before `Aiur.WorkflowStore` publishes it
  (#3961), and keeps a rejected reload visible until a later reload succeeds.

  Config consumers read through `Aiur.Config.settings!/0`, which raises on a
  config that fails schema validation. The store used to publish any config
  that parsed as YAML, so one bad edit to `.aiur/config` (an `agent.routing`
  effort the backend does not accept) crashed `Aiur.Orchestrator` and took the
  daemon down with it. A rejected reload now keeps the last known good config,
  raises one `system.config.reload_rejected` alert per broken revision, and is
  shown by `aiur status`. The next successful reload clears it.

  The rejection lives in the store's ETS table, so a store restart drops it
  together with the cached config it was guarding.
  """

  require Logger

  alias Aiur.{Alerts, Config}
  alias Aiur.WorkflowStore.Cache

  @topic "system.config.reload_rejected"
  @key :reload_rejection

  @type rejection :: %{path: Path.t(), message: String.t(), rejected_at: DateTime.t()}

  @doc "Returns `:ok` when the workflow passes the same schema parse `Aiur.Config.settings!/0` runs."
  @spec validate(map()) :: :ok | {:error, term()}
  def validate(workflow) do
    case Config.settings_from({:ok, workflow}) do
      {:ok, _settings} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Records a rejected reload of `path` and raises the operator alert."
  @spec reject(Path.t(), term()) :: :ok
  def reject(path, reason) do
    message = Config.format_config_error(reason)
    Logger.error("Failed to reload workflow path=#{path} reason=#{inspect(reason)}; keeping last known good configuration")
    safe(fn -> :ets.insert(Cache.table(), {@key, %{path: path, message: message, rejected_at: DateTime.utc_now()}}) end)

    emit(@topic,
      message: "Config reload rejected; keeping the last known good config",
      reason: message,
      needs_attention: true,
      severity: "warning"
    )
  end

  @doc "Clears an active rejection after a successful reload. A no-op when none is active."
  @spec clear() :: :ok
  def clear do
    case current() do
      nil ->
        :ok

      %{path: path} ->
        safe(fn -> :ets.delete(Cache.table(), @key) end)
        emit(@topic <> ".resolved", message: "Config reload accepted", reason: "#{path} loads cleanly again", needs_attention: false)
    end
  end

  @spec current() :: rejection() | nil
  def current do
    case :ets.lookup(Cache.table(), @key) do
      [{@key, rejection}] -> rejection
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Prints the active rejection for `aiur status`; prints nothing when the config is current."
  @spec print_status() :: :ok
  def print_status do
    case current() do
      nil -> :ok
      %{path: path, message: message} -> IO.puts("CONFIG RELOAD REJECTED path=#{path} (running on the last known good config): #{message}")
    end
  end

  # The alert pipeline must never take the config store down.
  defp emit(topic, opts) do
    Alerts.emit_system(topic, opts)
    :ok
  rescue
    error ->
      Logger.warning("config reload alert #{topic} failed: #{Exception.message(error)}")
      :ok
  catch
    _kind, _reason -> :ok
  end

  defp safe(fun) do
    _ = fun.()
    :ok
  rescue
    ArgumentError -> :ok
  end
end
