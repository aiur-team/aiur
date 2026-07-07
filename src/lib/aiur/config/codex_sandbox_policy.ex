defmodule Aiur.Config.CodexSandboxPolicy do
  @moduledoc false

  alias Aiur.PathSafety

  @spec resolve(map() | nil, Path.t() | nil, Path.t() | nil) :: map()
  def resolve(policy, workspace, fallback_workspace_root)

  def resolve(%{} = policy, workspace, _fallback_workspace_root) do
    maybe_add_workspace_writable_root(policy, expand_configured_workspace(workspace))
  end

  def resolve(_policy, workspace, fallback_workspace_root) do
    workspace
    |> default_workspace_root(fallback_workspace_root)
    |> expand_local_workspace_root()
    |> default_policy()
  end

  @spec resolve_runtime(map() | nil, Path.t() | nil, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime(policy, workspace, fallback_workspace_root, opts \\ [])

  def resolve_runtime(%{} = policy, workspace, _fallback_workspace_root, opts) do
    with {:ok, writable_roots} <- runtime_policy_writable_roots(workspace, opts) do
      {:ok, maybe_add_workspace_writable_roots(policy, writable_roots)}
    end
  end

  def resolve_runtime(_policy, workspace, fallback_workspace_root, opts) do
    workspace
    |> default_workspace_root(fallback_workspace_root)
    |> default_runtime_policy(opts)
  end

  defp default_policy(workspace) when is_binary(workspace), do: default_policy([workspace])

  defp default_policy(writable_roots) when is_list(writable_roots) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => writable_roots,
      "readOnlyAccess" => %{"type" => "fullAccess"},
      # Elixir 1.19 Mix opens a loopback TCP listener for Mix.Sync.PubSub during
      # standard project startup. Denying network access breaks normal gates
      # like `mix test` before project code runs.
      "networkAccess" => true,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_policy(remote_workspace_writable_roots(workspace_root))}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_policy(local_workspace_writable_roots(canonical_workspace_root))}
      end
    end
  end

  defp default_runtime_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp runtime_policy_writable_roots(workspace, opts) when is_binary(workspace) do
    if String.trim(workspace) == "" do
      {:ok, []}
    else
      do_runtime_policy_writable_roots(workspace, opts)
    end
  end

  defp runtime_policy_writable_roots(_workspace, _opts), do: {:ok, []}

  defp do_runtime_policy_writable_roots(workspace, opts) do
    if Keyword.get(opts, :remote, false) do
      {:ok, remote_workspace_writable_roots(workspace)}
    else
      workspace
      |> expand_local_workspace_root()
      |> PathSafety.canonicalize()
      |> case do
        {:ok, canonical_workspace} -> {:ok, local_workspace_writable_roots(canonical_workspace)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp expand_configured_workspace(workspace) when is_binary(workspace) do
    if String.trim(workspace) == "" do
      nil
    else
      expand_local_workspace_root(workspace)
    end
  end

  defp expand_configured_workspace(_workspace), do: nil

  defp maybe_add_workspace_writable_root(policy, nil), do: policy

  defp maybe_add_workspace_writable_root(%{} = policy, workspace_root)
       when is_binary(workspace_root) do
    maybe_add_workspace_writable_roots(policy, [workspace_root])
  end

  defp maybe_add_workspace_writable_roots(%{} = policy, writable_roots) when is_list(writable_roots) do
    case Map.get(policy, "type") || Map.get(policy, :type) do
      "workspaceWrite" ->
        existing_roots = Map.get(policy, "writableRoots") || Map.get(policy, :writableRoots) || []
        existing_roots = if is_list(existing_roots), do: existing_roots, else: []

        Map.put(policy, "writableRoots", append_unique(existing_roots, writable_roots))

      _ ->
        policy
    end
  end

  defp local_workspace_writable_roots(workspace_root) do
    append_unique([workspace_root], local_git_metadata_root(workspace_root))
  end

  defp remote_workspace_writable_roots(workspace_root) do
    append_unique([workspace_root], Path.join(workspace_root, ".git"))
  end

  defp local_git_metadata_root(workspace_root) do
    with git when is_binary(git) <- System.find_executable("git"),
         {_output, 0} <- System.cmd(git, ["-C", workspace_root, "rev-parse", "--is-inside-work-tree"], stderr_to_stdout: true),
         {git_dir, 0} <- System.cmd(git, ["-C", workspace_root, "rev-parse", "--git-dir"], stderr_to_stdout: true),
         expanded_git_dir <- expand_git_dir(workspace_root, String.trim(git_dir)),
         {:ok, canonical_git_dir} <- PathSafety.canonicalize(expanded_git_dir),
         true <- path_inside?(canonical_git_dir, workspace_root) do
      canonical_git_dir
    else
      _ -> nil
    end
  end

  defp expand_git_dir(workspace_root, git_dir) do
    case Path.type(git_dir) do
      :absolute -> Path.expand(git_dir)
      _ -> Path.expand(git_dir, workspace_root)
    end
  end

  defp path_inside?(path, root) do
    String.starts_with?(path <> "/", root <> "/")
  end

  defp append_unique(values, nil), do: values

  defp append_unique(values, new_values) when is_list(new_values) do
    Enum.reduce(new_values, values, &append_unique(&2, &1))
  end

  defp append_unique(values, value) do
    if value in values, do: values, else: values ++ [value]
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "aiur_workspaces"))
  end
end
