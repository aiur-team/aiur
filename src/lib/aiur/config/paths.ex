defmodule Aiur.Config.Paths do
  @moduledoc """
  Canonical path-resolution helpers shared across modules that persist
  per-issue or repo-scoped state.

  Single source of truth for:

    * `log_root_dir/0` — the directory under which `<repo>.<id>.log`,
      `<repo>.<id>.subscriptions.json`, `<repo>.event_id`, and similar
      files live. Respects `Application.get_env(:aiur, :log_file)` (set
      by the `--logs-root` CLI flag), falls back to `<cwd>/log`.
    * `repo_name/0` — the sanitized identifier used to prefix per-issue
      files. Comes from `Aiur.Tracker.project_identity/0`; failure-safe.
    * `sanitize/1` — replaces shell/path-unsafe characters with `_` so
      values from external sources (label slugs, repo names) can't escape
      filesystem boundaries.

  Consumers: `Aiur.IssueLog`, `Aiur.LogFile`, and (forthcoming) the
  `Aiur.Events.IdGenerator` + `Aiur.Events.SubscriptionStore` modules.
  """

  alias Aiur.PathSafety
  alias Aiur.Tracker

  @doc """
  Returns the directory where per-issue and per-repo persistent files
  live. Defaults to `<cwd>/log` when no `--logs-root` was set.
  """
  @spec log_root_dir() :: Path.t()
  def log_root_dir do
    case Application.get_env(:aiur, :log_file) do
      path when is_binary(path) -> Path.dirname(path)
      _ -> Path.join(File.cwd!(), "log")
    end
  end

  @doc """
  Resolves the owner-only Decision state directory.

  An `Application` env override (tests, and any future explicit
  configuration) wins outright and skips validation below — it is a
  trusted, explicit value. Otherwise the directory is built from
  `AIUR_BG_STATE_DIR`, the `AIUR_INSTANCE_KEY` (already a truncated
  sha256 of the launcher-resolved project root — see
  `aiur-engine.sh`'s `aiur_instance_key`), and the tracker project
  identity.

  Fails closed instead of silently sharing state across instances or
  projects: an empty `AIUR_INSTANCE_KEY` (the explicit shared-identity
  override `aiur-engine.sh` still honors) or an unavailable/default
  project identity would leave `repo_name/0`'s last-path-segment
  fallback as the only discriminator, which collapses when two
  projects share a directory name. The resolved path is also
  canonicalized and asserted to stay beneath the configured root (the
  `Aiur.PathSafety` / `Aiur.Workspace.Layout` root-containment
  precedent), so a stray `.`/`..` component cannot escape the leaf.
  """
  @spec decision_state_dir() :: {:ok, Path.t()} | {:error, atom()}
  def decision_state_dir do
    case Application.get_env(:aiur, :decision_state_dir) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> resolve_decision_state_dir()
    end
  end

  @doc """
  Returns the sanitized last segment of the tracker's project identity,
  or `"aiur"` if no identity is available. Safe to use as a filename
  prefix.
  """
  @spec repo_name() :: String.t()
  def repo_name do
    case safe_project_identity() do
      identity when is_binary(identity) and identity != "" ->
        identity
        |> String.split("/")
        |> List.last()
        |> sanitize()
        |> default_if_empty()

      _ ->
        "aiur"
    end
  end

  @doc """
  Replaces any character outside `[A-Za-z0-9._-]` with `_`. Used for
  per-issue identifiers and repo names that may contain `/`, `:`, or
  other characters that would break filesystem paths.
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(name) when is_binary(name) do
    String.replace(name, ~r/[^A-Za-z0-9._-]/, "_")
  end

  @doc """
  Like `sanitize/1`, but substitutes `default` when `value` is `nil`.

  Canonical home of the former per-site `safe_identifier/1` copies
  (workspace dirs, opencode model ids/session rows, hook-settings temp
  files, test-reset workspace paths). These names are join keys across
  subsystems: they must all derive from this one function, byte-identically,
  or cross-subsystem lookups break.
  """
  @spec sanitize(String.t() | nil, String.t()) :: String.t()
  def sanitize(value, default) when is_binary(default) do
    sanitize(value || default)
  end

  defp safe_project_identity do
    Tracker.project_identity()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp default_if_empty(""), do: "aiur"
  defp default_if_empty(value), do: value

  defp resolve_decision_state_dir do
    with {:ok, instance_key} <- decision_instance_key(),
         {:ok, project_leaf} <- decision_project_leaf() do
      root = decision_state_root()
      candidate = Path.join([root, instance_key, project_leaf])
      contain_within_root(root, candidate)
    end
  end

  defp decision_instance_key do
    case System.get_env("AIUR_INSTANCE_KEY") do
      key when is_binary(key) and key != "" -> {:ok, sanitize(key)}
      _ -> {:error, :missing_instance_key}
    end
  end

  # Rejects unavailable identity outright rather than falling back to a
  # shared default the way `repo_name/0` does — `AIUR_INSTANCE_KEY` already
  # guarantees per-project uniqueness once validated non-empty, so a
  # genuinely-resolved leaf that happens to read "aiur" (e.g. this very
  # repo) is not itself a collision risk and must not be rejected.
  defp decision_project_leaf do
    with identity when is_binary(identity) and identity != "" <- safe_project_identity(),
         leaf <- identity |> String.split("/") |> List.last() |> sanitize(),
         false <- leaf in ["", ".", ".."] do
      {:ok, leaf}
    else
      _ -> {:error, :missing_project_identity}
    end
  end

  defp decision_state_root do
    case System.get_env("AIUR_BG_STATE_DIR") do
      root when is_binary(root) and root != "" -> root
      _ -> Path.join(File.cwd!(), ".aiur-state")
    end
  end

  defp contain_within_root(root, candidate) do
    case PathSafety.contained?(root, candidate) do
      {:ok, %{root: same, candidate: same}} -> {:error, :decision_path_equals_root}
      {:ok, %{candidate: canonical_candidate}} -> {:ok, canonical_candidate}
      {:error, :outside_root} -> {:error, :decision_path_outside_root}
      {:error, :unreadable} -> {:error, :decision_path_unreadable}
    end
  end
end
