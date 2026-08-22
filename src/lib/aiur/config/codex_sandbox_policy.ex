defmodule Aiur.Config.CodexSandboxPolicy do
  @moduledoc false

  alias Aiur.PathSafety

  @configured_roots_key "agent.codex.turn_sandbox_policy.writableRoots"

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

  def resolve_runtime(%{} = policy, workspace, fallback_workspace_root, opts) do
    effective_workspace = default_workspace_root(workspace, fallback_workspace_root)

    with {:ok, writable_roots} <- runtime_policy_writable_roots(effective_workspace, opts) do
      if Keyword.get(opts, :remote, false) do
        {:ok, replace_workspace_writable_roots(policy, writable_roots)}
      else
        with {:ok, policy} <- canonicalize_configured_writable_roots(policy) do
          {:ok, maybe_add_workspace_writable_roots(policy, writable_roots)}
        end
      end
    end
  end

  def resolve_runtime(_policy, workspace, fallback_workspace_root, opts) do
    workspace
    |> default_workspace_root(fallback_workspace_root)
    |> default_runtime_policy(opts)
  end

  @doc false
  @spec add_runtime_writable_roots(map(), [Path.t()]) :: {:ok, map()} | {:error, term()}
  def add_runtime_writable_roots(policy, roots) when is_map(policy) and is_list(roots) do
    with {:ok, canonical_roots} <- canonicalize_additional_roots(roots) do
      {:ok, maybe_add_workspace_writable_roots(policy, canonical_roots)}
    end
  end

  @doc false
  @spec validate_configured_writable_roots(map() | nil) :: :ok | {:error, term()}
  def validate_configured_writable_roots(policy) do
    case canonicalize_configured_writable_roots(policy) do
      {:ok, _policy} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec default_policy(Path.t()) :: map()
  def default_policy(workspace) when is_binary(workspace), do: policy_for_roots([workspace])

  defp policy_for_roots(writable_roots) when is_list(writable_roots) do
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
      {:ok, policy_for_roots(remote_workspace_writable_roots(workspace_root))}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root),
           {:ok, additional_roots} <- additional_writable_roots(opts) do
        writable_roots =
          canonical_workspace_root
          |> local_workspace_writable_roots()
          |> append_unique(additional_roots)

        {:ok, policy_for_roots(writable_roots)}
      end
    end
  end

  defp default_runtime_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp runtime_policy_writable_roots(workspace, opts) when is_binary(workspace) do
    if String.trim(workspace) == "" do
      runtime_policy_additional_roots([], opts)
    else
      do_runtime_policy_writable_roots(workspace, opts)
    end
  end

  defp runtime_policy_writable_roots(_workspace, opts), do: runtime_policy_additional_roots([], opts)

  defp do_runtime_policy_writable_roots(workspace, opts) do
    if Keyword.get(opts, :remote, false) do
      {:ok, remote_workspace_writable_roots(workspace)}
    else
      workspace
      |> expand_local_workspace_root()
      |> PathSafety.canonicalize()
      |> case do
        {:ok, canonical_workspace} ->
          canonical_workspace
          |> local_workspace_writable_roots()
          |> runtime_policy_additional_roots(opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp runtime_policy_additional_roots(writable_roots, opts) do
    if Keyword.get(opts, :remote, false) do
      {:ok, writable_roots}
    else
      with {:ok, additional_roots} <- additional_writable_roots(opts) do
        {:ok, append_unique(writable_roots, additional_roots)}
      end
    end
  end

  defp additional_writable_roots(opts) do
    case Keyword.get(opts, :additional_writable_roots, []) do
      roots when is_list(roots) -> canonicalize_additional_roots(roots)
      roots -> {:error, {:unsafe_turn_sandbox_policy, {:invalid_writable_roots, roots}}}
    end
  end

  defp canonicalize_additional_roots(roots) do
    Enum.reduce_while(roots, {:ok, []}, fn
      root, {:ok, canonical_roots} when is_binary(root) ->
        case PathSafety.canonicalize(root) do
          {:ok, canonical_root} -> {:cont, {:ok, append_unique(canonical_roots, canonical_root)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      root, _acc ->
        {:halt, {:error, {:unsafe_turn_sandbox_policy, {:invalid_writable_root, root}}}}
    end)
  end

  defp canonicalize_configured_writable_roots(%{} = policy) do
    if workspace_write_policy?(policy) do
      with {:ok, roots} <- configured_writable_roots(policy),
           {:ok, canonical_roots} <- validate_configured_roots(roots) do
        {:ok, Map.put(policy, "writableRoots", canonical_roots)}
      end
    else
      {:ok, policy}
    end
  end

  defp canonicalize_configured_writable_roots(policy), do: {:ok, policy}

  defp configured_writable_roots(policy) do
    case Map.get(policy, "writableRoots") || Map.get(policy, :writableRoots) || [] do
      roots when is_list(roots) -> {:ok, roots}
      roots -> configured_root_error(roots, :not_a_list)
    end
  end

  defp validate_configured_roots(roots) do
    Enum.reduce_while(roots, {:ok, []}, fn root, {:ok, canonical_roots} ->
      case validate_configured_root(root) do
        {:ok, canonical_root} -> {:cont, {:ok, append_unique(canonical_roots, canonical_root)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_configured_root(root) when is_binary(root) do
    expanded_root = Path.expand(root)

    if String.trim(root) == "" do
      configured_root_error(expanded_root, :blank)
    else
      with {:ok, canonical_root} <- canonicalize_configured_root(expanded_root),
           :ok <- configured_root_directory(canonical_root),
           :ok <- probe_configured_root(canonical_root) do
        {:ok, canonical_root}
      end
    end
  end

  defp validate_configured_root(root), do: configured_root_error(root, :invalid_path)

  defp canonicalize_configured_root(expanded_root) do
    case PathSafety.canonicalize(expanded_root) do
      {:ok, canonical_root} -> {:ok, canonical_root}
      {:error, reason} -> configured_root_error(expanded_root, {:canonicalize_failed, reason})
    end
  end

  defp configured_root_directory(root) do
    case File.stat(root) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{}} -> configured_root_error(root, :not_a_directory)
      {:error, :enoent} -> configured_root_error(root, :does_not_exist)
      {:error, reason} -> configured_root_error(root, {:unavailable, reason})
    end
  end

  defp probe_configured_root(root) do
    probe =
      Path.join(
        root,
        ".aiur-write-probe-#{:os.getpid()}-#{System.unique_integer([:positive, :monotonic])}"
      )

    case File.open(probe, [:write, :exclusive]) do
      {:ok, io} ->
        :ok = File.close(io)

        case File.rm(probe) do
          :ok -> :ok
          {:error, reason} -> configured_root_error(root, {:not_writable, {:cleanup_failed, reason}})
        end

      {:error, reason} ->
        configured_root_error(root, {:not_writable, reason})
    end
  end

  defp configured_root_error(path, reason) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_configured_writable_root, %{config_key: @configured_roots_key, path: path, reason: reason}}}}
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
    if workspace_write_policy?(policy) do
      existing_roots = Map.get(policy, "writableRoots") || Map.get(policy, :writableRoots) || []
      existing_roots = if is_list(existing_roots), do: existing_roots, else: []

      Map.put(policy, "writableRoots", append_unique(existing_roots, writable_roots))
    else
      policy
    end
  end

  defp replace_workspace_writable_roots(%{} = policy, writable_roots) when is_list(writable_roots) do
    if workspace_write_policy?(policy) do
      Map.put(policy, "writableRoots", writable_roots)
    else
      policy
    end
  end

  defp workspace_write_policy?(policy) do
    (Map.get(policy, "type") || Map.get(policy, :type)) == "workspaceWrite"
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
