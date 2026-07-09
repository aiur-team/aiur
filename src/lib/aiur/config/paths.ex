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
end
