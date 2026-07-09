defmodule Aiur.Workspace.Layout do
  @moduledoc "Pure path policy: where a workspace lives (repo-namespaced layout) and whether a path is legal under the configured root."

  alias Aiur.{Config, PathSafety}

  @type worker_host :: String.t() | nil

  @spec pr_anchored_workspace?(Path.t()) :: boolean()
  def pr_anchored_workspace?(workspace) do
    String.starts_with?(Path.basename(workspace), "pr-")
  end

  @spec workspace_path_for_issue(String.t(), worker_host()) :: {:ok, Path.t()} | {:error, term()}
  def workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> issue_workspace_path(safe_id)
    |> PathSafety.canonicalize()
  end

  def workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, issue_workspace_path(Config.settings!().workspace.root, safe_id)}
  end

  @spec issue_workspace_path(Path.t(), String.t()) :: Path.t()
  # Namespace per-issue workspaces by repo so two repos sharing a root never
  # collide on issue number: <root>/<owner>/<repo>/<issue>. The append is
  # idempotent — if the configured root already ends with the repo segment
  # (e.g. `aiur init` baked owner/name into it), it is not doubled. Trackers
  # without a repo segment (memory, or a misconfigured provider) fall back to
  # <root>/<issue>.
  def issue_workspace_path(root, safe_id) do
    case repo_segment() do
      nil ->
        Path.join(root, safe_id)

      segment ->
        trimmed = String.trim_trailing(root, "/")

        if trimmed == segment or String.ends_with?(trimmed, "/" <> segment) do
          Path.join(trimmed, safe_id)
        else
          Path.join([trimmed, segment, safe_id])
        end
    end
  end

  @spec safe_identifier(term()) :: String.t()
  def safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  @spec validate_workspace_path(Path.t(), worker_host()) :: :ok | {:error, term()}
  def validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  def validate_workspace_path(workspace, worker_host)
      when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  # Full `owner/name` segment (e.g. "its-applekid/actions"), kept as nested dirs
  # so forks of the same repo name never collide (its-applekid/actions vs
  # ethereum-optimism/actions). Linear uses project_slug (no owner). Each path
  # component is sanitized and traversal parts (".", "..", "") are dropped so the
  # segment can never escape the workspace root.
  defp repo_segment do
    settings = Config.settings!()

    raw =
      case settings.tracker.kind do
        "github" -> settings.tracker.github.repo
        "linear" -> settings.tracker.linear.project_slug
        _ -> nil
      end

    case raw do
      value when is_binary(value) and value != "" -> safe_repo_segment(value)
      _ -> nil
    end
  end

  defp safe_repo_segment(value) do
    segment =
      value
      |> String.split("/")
      |> Enum.map(&safe_identifier/1)
      |> Enum.reject(&(&1 in ["", ".", ".."]))
      |> Enum.join("/")

    if segment == "", do: nil, else: segment
  end
end
