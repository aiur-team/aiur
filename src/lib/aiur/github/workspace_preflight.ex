defmodule Aiur.GitHub.WorkspacePreflight do
  @moduledoc "GitHub connectivity and authentication checks before workspace hooks."
  @behaviour Aiur.Workspace.Preflight

  alias Aiur.GitHub.{AuthPreflight, Client, Config, Tracker}
  alias Aiur.Workspace.Context

  @impl true
  def run(workspace, worker_host) do
    if Application.get_env(:aiur, :workspace_github_preflight_enabled, true) == true do
      run_preflight(workspace, worker_host)
    else
      :ok
    end
  end

  defp run_preflight(workspace, worker_host) do
    fun =
      Application.get_env(:aiur, :workspace_github_preflight_fun, fn _workspace, _worker_host ->
        Tracker.auth_preflight()
      end)

    cond do
      is_function(fun, 2) -> fun.(workspace, worker_host)
      is_function(fun, 1) -> fun.(workspace)
      is_function(fun, 0) -> fun.()
      true -> {:error, {:invalid_workspace_github_preflight_fun, inspect(fun)}}
    end
  end

  @impl true
  def local_hold?(reason), do: AuthPreflight.local_hold_reason?(reason)

  @impl true
  def failure_message(workspace, issue_context, reason) do
    repo = Config.repo() || "(unknown repo)"
    formatted = Client.format_auth_preflight_error(reason)

    "GitHub workspace preflight failed #{Context.log_context(issue_context)} workspace=#{workspace} " <>
      "repo=#{repo}. Probe: #{probe(repo)}. Reason: #{formatted}"
  end

  defp probe("(unknown repo)") do
    "GET https://api.github.com/rate_limit"
  end

  defp probe(repo) do
    "GET https://api.github.com/rate_limit; " <>
      "GET https://api.github.com/repos/#{repo}; " <>
      "GET https://api.github.com/repos/#{repo}/issues?state=open&per_page=1"
  end
end
