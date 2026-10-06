defmodule Aiur.AgentCompaction.Store do
  @moduledoc "Daemon-owned durable compaction outcomes, outside agent workspaces."

  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @spec load(String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def load(identifier, opts \\ []) when is_binary(identifier) do
    with {:ok, dir} <- state_dir(opts) do
      JsonStore.read(path_for(identifier, dir, opts))
    end
  end

  @spec save(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def save(identifier, state, opts \\ []) when is_binary(identifier) and is_map(state) do
    with {:ok, dir} <- state_dir(opts) do
      JsonStore.write!(path_for(identifier, dir, opts), state)
    end
  rescue
    error -> {:error, error}
  end

  @doc false
  def path_for(identifier, dir, opts \\ []) do
    repo = Keyword.get(opts, :repo_name) || Paths.repo_name()
    Path.join(dir, "#{Paths.sanitize(repo)}.#{Paths.sanitize(identifier)}.json")
  end

  defp state_dir(opts) do
    case Keyword.get(opts, :dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> Paths.agent_compaction_state_dir()
    end
  end
end
