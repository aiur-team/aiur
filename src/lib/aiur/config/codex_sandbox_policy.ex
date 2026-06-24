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
    with {:ok, workspace_root} <- runtime_policy_workspace_root(workspace, opts) do
      {:ok, maybe_add_workspace_writable_root(policy, workspace_root)}
    end
  end

  def resolve_runtime(_policy, workspace, fallback_workspace_root, opts) do
    workspace
    |> default_workspace_root(fallback_workspace_root)
    |> default_runtime_policy(opts)
  end

  defp default_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp runtime_policy_workspace_root(workspace, opts) when is_binary(workspace) do
    if String.trim(workspace) == "" do
      {:ok, nil}
    else
      if Keyword.get(opts, :remote, false) do
        {:ok, workspace}
      else
        workspace
        |> expand_local_workspace_root()
        |> PathSafety.canonicalize()
      end
    end
  end

  defp runtime_policy_workspace_root(_workspace, _opts), do: {:ok, nil}

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
    case Map.get(policy, "type") || Map.get(policy, :type) do
      "workspaceWrite" ->
        writable_roots = Map.get(policy, "writableRoots") || Map.get(policy, :writableRoots) || []
        writable_roots = if is_list(writable_roots), do: writable_roots, else: []

        Map.put(policy, "writableRoots", append_unique(writable_roots, workspace_root))

      _ ->
        policy
    end
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
