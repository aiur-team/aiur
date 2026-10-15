defmodule Aiur.RepoBase.StateTree do
  @moduledoc """
  Creates the canonical per-repository state tree for `Aiur.RepoBase` and owns
  the path safety checks every state writer and migration step relies on.
  """

  alias Aiur.Config.Paths

  @cache_sidecars Paths.repo_cache_sidecars()

  @doc false
  @spec cache_sidecars() :: [String.t()]
  def cache_sidecars, do: @cache_sidecars

  @doc false
  @spec cache_sidecar_paths(Path.t()) :: [Path.t()]
  defdelegate cache_sidecar_paths(root), to: Paths, as: :repo_cache_sidecar_paths

  @doc false
  @spec ensure_state_tree_at(Path.t()) :: :ok | {:error, term()}
  def ensure_state_tree_at(node) do
    findings = Path.join([node, "meta", "findings.ndjson"])
    asks = Path.join([node, "meta", "asks.ndjson"])

    with :ok <- ensure_state_node_safe(node),
         :ok <- File.mkdir_p(node),
         :ok <- create_state_directories(node),
         :ok <- ensure_state_path_safe(node, findings),
         :ok <- ensure_state_path_safe(node, asks),
         :ok <- File.touch(findings),
         :ok <- File.touch(asks) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec ensure_state_node_safe(Path.t()) :: :ok | {:error, term()}
  def ensure_state_node_safe(node) do
    case File.lstat(node) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:repo_base_state_path_symlink, node}}
      {:ok, _stat} -> {:error, {:repo_base_state_path_invalid_root, node}}
      {:error, reason} -> {:error, {:repo_base_state_path_invalid_root, node, reason}}
    end
  end

  defp create_state_directories(node) do
    [
      Path.join(node, "latest"),
      Path.join(node, "builds"),
      Path.join(node, "analytics"),
      Path.join(node, "meta"),
      Path.join([node, "meta", "retros"]),
      Path.join(node, "executor")
      | cache_sidecar_paths(node)
    ]
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case ensure_state_path_safe(node, path) do
        :ok ->
          create_state_directory(path)

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp create_state_directory(path) do
    case File.mkdir_p(path) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:repo_state_tree_create_failed, path, reason}}}
    end
  end

  @doc false
  @spec ensure_state_path_safe(Path.t(), Path.t()) :: :ok | {:error, term()}
  def ensure_state_path_safe(node, path) do
    case File.lstat(node) do
      {:ok, %File.Stat{type: :directory}} -> ensure_state_path_under_node(node, path)
      {:ok, _stat} -> {:error, {:repo_base_state_path_invalid_root, node}}
      {:error, reason} -> {:error, {:repo_base_state_path_invalid_root, node, reason}}
    end
  end

  defp ensure_state_path_under_node(node, path) do
    relative = Path.relative_to(path, node)

    with :ok <- ensure_relative_state_path(relative) do
      state_path_components_safe(node, Path.split(relative))
    end
  end

  defp ensure_relative_state_path(relative) do
    if relative == "." or relative == ".." or String.starts_with?(relative, "../") do
      {:error, {:repo_base_state_path_outside_node, relative}}
    else
      :ok
    end
  end

  defp state_path_components_safe(_path, []), do: :ok

  defp state_path_components_safe(path, [component | rest]) do
    next = Path.join(path, component)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:repo_base_state_path_symlink, next}}
      {:ok, _stat} -> state_path_components_safe(next, rest)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:repo_base_state_path_inspection_failed, next, reason}}
    end
  end
end
