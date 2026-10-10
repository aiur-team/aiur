defmodule Aiur.IssueLog.Paths do
  @moduledoc false

  alias Aiur.Config.Paths, as: ConfigPaths
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.TrackerIdentity

  @spec log_path(AgentEvents.agent_identifier() | TrackerIdentity.t()) :: String.t()
  def log_path(identifier) when is_binary(identifier) do
    issue_log_path(configured_repository_scope(), identifier, ".log")
  end

  def log_path(%TrackerIdentity{} = identity) do
    case TrackerIdentity.github_key(identity) do
      {:github, owner, repository, _provider_id} ->
        issue_log_path(repository_scope(owner, repository), identity.identifier, ".log")

      nil ->
        raise ArgumentError, "IssueLog path requires a joinable tracker identity"
    end
  end

  @spec event_log_path(AgentEvents.agent_identifier() | TrackerIdentity.t()) :: String.t()
  def event_log_path(identifier) when is_binary(identifier) do
    issue_log_path(configured_repository_scope(), identifier, ".events.log")
  end

  def event_log_path(%TrackerIdentity{} = identity) do
    case TrackerIdentity.github_key(identity) do
      {:github, owner, repository, _provider_id} ->
        issue_log_path(repository_scope(owner, repository), identity.identifier, ".events.log")

      nil ->
        raise ArgumentError, "IssueLog path requires a joinable tracker identity"
    end
  end

  @spec transcript_path(AgentEvents.agent_identifier() | TrackerIdentity.t()) :: String.t()
  def transcript_path(identifier) when is_binary(identifier) do
    issue_log_path(configured_repository_scope(), identifier, ".agent_events.jsonl")
  end

  def transcript_path(%TrackerIdentity{} = identity) do
    case TrackerIdentity.github_key(identity) do
      {:github, owner, repository, _provider_id} ->
        issue_log_path(repository_scope(owner, repository), identity.identifier, ".agent_events.jsonl")

      nil ->
        raise ArgumentError, "IssueLog path requires a joinable tracker identity"
    end
  end

  defp log_root_dir, do: ConfigPaths.log_root_dir()

  # Deliberately `explicit_configured_repo/0`, not `configured_repo/0`: this
  # scope names every log, event log and transcript file on disk, and the
  # writer registry key that keeps one process per ticket. `configured_repo/0`
  # falls back to the checkout's `origin` remote (#2518), so reading it here
  # would rename every file for an install that never set `tracker.github.repo`
  # — the existing history would still be on disk but unreachable through
  # `history/2` and `read_tail/2`, and a resumed ticket would append to a fresh
  # empty file. Durable paths only move when an operator moves them.
  @spec configured_repository_scope() :: String.t()
  def configured_repository_scope do
    case GitHubConfig.explicit_configured_repo() do
      {:ok, {owner, repository}} -> repository_scope(owner, repository)
      {:error, _reason} -> repo_name()
    end
  end

  @spec repository_scope(String.t(), String.t()) :: String.t()
  def repository_scope(owner, repository) do
    encoded = Base.url_encode64("#{String.downcase(owner)}/#{String.downcase(repository)}", padding: false)
    "github-" <> encoded
  end

  defp issue_log_path(scope, identifier, suffix) do
    Path.join(log_root_dir(), "#{scope}.#{sanitize(identifier)}#{suffix}")
  end

  defp repo_name, do: ConfigPaths.repo_name()
  defp sanitize(name), do: ConfigPaths.sanitize(name)
end
