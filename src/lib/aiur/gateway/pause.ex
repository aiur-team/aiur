defmodule Aiur.Gateway.Pause do
  @moduledoc """
  The whole-gateway pause: one file beside the project state leaves, mirrored into every
  project's orchestrator as `gateway_paused`. A project's own flag (`global-pause.json` in its
  state root) is separate, so resuming the gateway never clears a project pause.

  Only a gateway with `projects:` reads it. An unreadable file holds dispatch paused, the same
  invariant as the project flag.
  """
  alias Aiur.Config.Paths
  alias Aiur.Orchestrator.GlobalPauseStore
  alias Aiur.Project.Context

  @topic "gateway:pause"
  @filename "gateway-pause.json"

  @doc "Sets the gateway pause, persists it, and tells every project's orchestrator."
  @spec set(boolean(), String.t()) :: {:ok, map()} | {:error, term()}
  def set(on?, source) when is_boolean(on?) and is_binary(source) do
    state = %{globally_paused: on?, paused_at: if(on?, do: DateTime.utc_now()), source: if(on?, do: source)}

    with {:ok, path} <- path(),
         :ok <- GlobalPauseStore.save(state, path: path) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, {:gateway_pause, on?, %{source: source}})
      {:ok, state}
    else
      {:error, reason} -> {:error, {:global_pause_persistence_failed, reason}}
    end
  end

  @doc "Boot value for a project's orchestrator: false with no project context."
  @spec initial() :: boolean()
  def initial, do: Context.current() != nil and paused?()

  @doc "The persisted flag; an unreadable file counts as paused."
  @spec paused?() :: boolean()
  def paused? do
    with {:ok, path} <- path(),
         {:ok, %{globally_paused: paused}} <- GlobalPauseStore.load(path: path) do
      paused
    else
      _unreadable -> true
    end
  end

  @spec subscribe() :: :ok
  def subscribe do
    if Context.current(), do: Phoenix.PubSub.subscribe(Aiur.PubSub, @topic)
    :ok
  end

  @spec path() :: {:ok, Path.t()} | {:error, term()}
  def path do
    case Application.get_env(:aiur, :gateway_pause_store_path) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> with {:ok, leaf} <- Paths.decision_state_dir(), do: {:ok, Path.join(Path.dirname(leaf), @filename)}
    end
  end
end
