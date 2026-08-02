defmodule Aiur.OpenAICompat.WorkspacePath do
  @moduledoc false

  alias Aiur.PathSafety

  @spec validate_workspace(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def validate_workspace(workspace, root)
      when is_binary(workspace) and is_binary(root) do
    with {:ok, %{root: canonical_root, candidate: canonical_workspace}} <-
           PathSafety.contained?(root, workspace),
         true <- canonical_workspace != canonical_root,
         true <- File.dir?(canonical_workspace) do
      {:ok, canonical_workspace}
    else
      {:error, :outside_root} ->
        {:error, {:invalid_workspace_cwd, :outside_workspace_root, Path.expand(workspace), Path.expand(root)}}

      {:error, :unreadable} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, Path.expand(workspace)}}

      false ->
        workspace_error(workspace, root)
    end
  end

  @spec resolve(Path.t(), term()) :: {:ok, Path.t()} | {:error, atom()}
  def resolve(workspace, relative)
      when is_binary(workspace) and is_binary(relative) do
    candidate = Path.expand(relative, Path.expand(workspace))

    case PathSafety.contained?(workspace, candidate) do
      {:ok, %{candidate: canonical}} -> {:ok, canonical}
      {:error, :outside_root} -> {:error, :outside_workspace}
      {:error, :unreadable} -> {:error, :unreadable_path}
    end
  end

  def resolve(_workspace, _relative), do: {:error, :invalid_path}

  defp workspace_error(workspace, root) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(root)

    if expanded_workspace == expanded_root,
      do: {:error, {:invalid_workspace_cwd, :workspace_root, expanded_workspace}},
      else: {:error, {:invalid_workspace_cwd, :not_directory, expanded_workspace}}
  end
end
