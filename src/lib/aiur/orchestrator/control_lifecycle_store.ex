defmodule Aiur.Orchestrator.ControlLifecycleStore do
  @moduledoc false

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.JsonStore
  alias Aiur.Orchestrator.ControlLifecycle

  @doc "Loads the last redacted lifecycle projection, treating unreadable state as empty."
  @spec load() :: ControlLifecycle.t()
  def load do
    case JsonStore.read(path_for(), %{}) do
      {:ok, persisted} ->
        ControlLifecycle.restore(persisted, [])

      {:error, reason} ->
        Logger.warning("Control lifecycle journal could not be read at #{path_for()}: #{inspect(reason)}; starting empty")
        ControlLifecycle.new()
    end
  end

  @doc "Best-effort durable write after each lifecycle transition."
  @spec save(ControlLifecycle.t()) :: :ok
  def save(%ControlLifecycle{} = lifecycle) do
    JsonStore.write!(path_for(), ControlLifecycle.dump(lifecycle))
    :ok
  rescue
    error ->
      Logger.warning("Control lifecycle journal could not be persisted at #{path_for()}: #{Exception.message(error)}")
      :ok
  end

  @doc "Converts any persisted unresolved request to `:expired` during daemon recovery."
  @spec expire_unresolved_on_recovery(ControlLifecycle.t(), keyword()) :: ControlLifecycle.t()
  def expire_unresolved_on_recovery(%ControlLifecycle{} = lifecycle, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    {_expired, lifecycle} = ControlLifecycle.expire_unresolved(lifecycle, :daemon_restart, now: now)
    lifecycle
  end

  @doc false
  @spec path_for() :: Path.t()
  def path_for do
    Application.get_env(:aiur, :control_lifecycle_store_path) ||
      Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.control-lifecycle.json")
  end
end
