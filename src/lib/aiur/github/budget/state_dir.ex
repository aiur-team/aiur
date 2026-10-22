defmodule Aiur.GitHub.Budget.StateDir do
  @moduledoc false

  alias Aiur.GitHub.Access.Settings
  @spec resolve(keyword()) :: Path.t()
  def resolve(opts) do
    case Keyword.get(opts, :state_dir) do
      path when is_binary(path) and path != "" -> explicit_dir(path)
      _ -> Settings.path(Settings.current(), :budget_dir)
    end
  end

  # Sandbox scope must override an explicit caller directory as before.
  defp explicit_dir(path) do
    if is_binary(System.get_env("AIUR_DEV_TEST_TICKET_IDS")),
      do: Settings.path(Settings.current(), :budget_dir),
      else: Path.expand(path)
  end

  @spec ensure(keyword()) :: :ok | {:error, term()}
  def ensure(opts) do
    path = resolve(opts)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_budget_state_dir, path, type}}
      {:error, :enoent} -> create_state_dir(path)
      {:error, reason} -> {:error, {:budget_state_dir_unavailable, path, reason}}
    end
  end

  defp create_state_dir(path) do
    case File.mkdir_p(path) do
      :ok ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} -> :ok
          {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_budget_state_dir, path, type}}
          {:error, reason} -> {:error, {:budget_state_dir_unavailable, path, reason}}
        end

      {:error, reason} ->
        {:error, {:budget_state_dir_unavailable, path, reason}}
    end
  end
end
