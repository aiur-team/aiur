defmodule Aiur.GitHub.AgentEnvironmentContributor do
  @moduledoc "GitHub guard environment for local and remote agent processes."
  @behaviour Aiur.AgentEnvironment.Contributor

  alias Aiur.AgentEnvironment.TestRunIsolation
  alias Aiur.AgentGitHubGuard
  alias Aiur.Config.Paths
  alias Aiur.GitHub.{AgentMarker, Budget, Credential}
  alias Aiur.GitHub.Config, as: GitHubConfig

  @impl true
  def port_env(workspace, opts) do
    real_gh = AgentGitHubGuard.real_gh()
    label_prefix = configured_label_prefix(opts)
    github_budget = Budget.guard_settings()

    [
      {~c"AIUR_AGENT_QUOTA_STATE_PATH", workspace |> AgentGitHubGuard.quota_dir() |> String.to_charlist()},
      {~c"AIUR_AGENT_BIN", workspace |> AgentGitHubGuard.bin_dir() |> String.to_charlist()},
      # SECURITY INVARIANT — see `AgentGitHubGuard.gh_config_dir/1`. An empty
      # agent-private `gh` config dir severs the operator keyring, which is
      # the identity that can bypass branch protection. Removing this makes
      # `env -u GITHUB_TOKEN -u GH_TOKEN gh pr review --approve` succeed as
      # the human again.
      {~c"GH_CONFIG_DIR", workspace |> AgentGitHubGuard.gh_config_dir() |> String.to_charlist()},
      {~c"AIUR_REAL_GH", if(real_gh, do: String.to_charlist(real_gh), else: false)},
      {~c"AIUR_GITHUB_LABEL_PREFIX", String.to_charlist(label_prefix)},
      # Single-account mode only: the marker the `gh` guard appends to comment
      # bodies the agent writes, so the daemon can later tell those comments
      # from ones the operator typed under the same login. `false` (unset) on
      # a separate-account install, where the author login already answers it
      # and the guard must not touch any body.
      {String.to_charlist(AgentMarker.env_var()), agent_comment_marker()},
      # The repository the agent was dispatched against, so the `gh` guard can
      # file a cached response under a resource identity (#2073 U6). `gh`
      # resolves the repo from the working directory, so the guard only trusts
      # this while the agent is inside the workspace below — a clone of some
      # other repository must not have its answers filed under this one.
      {~c"AIUR_GITHUB_REPO", configured_repo_slug()},
      {~c"AIUR_GITHUB_BUDGET_ROOT", Budget.state_dir() |> String.to_charlist()},
      # #2356: the path to the token file the daemon wrote for the `gh` guard.
      # This is a PATH, not a credential — the raw token lives on disk and the
      # wrapper injects it only into a governed call's real `gh` child, so the
      # agent environment itself never carries `GITHUB_TOKEN`/`GH_TOKEN`.
      {~c"AIUR_GITHUB_CREDENTIAL_FILE", AgentGitHubGuard.agent_token_path() |> String.to_charlist()},
      {~c"AIUR_GITHUB_BUDGET_BROKER", workspace |> AgentGitHubGuard.budget_broker_path() |> String.to_charlist()},
      {~c"AIUR_GITHUB_BUDGET_CONSUMER", "workspace:#{workspace}" |> String.to_charlist()},
      {~c"AIUR_GITHUB_BUDGET_IDENTITY_KEY", publication_credential_key(opts) |> String.to_charlist()},
      {~c"AIUR_GITHUB_MAX_INFLIGHT", github_budget.max_inflight |> Integer.to_string() |> String.to_charlist()},
      {~c"AIUR_GITHUB_MAX_INFLIGHT_PER_ENDPOINT", github_budget.max_inflight_per_endpoint |> Integer.to_string() |> String.to_charlist()},
      {~c"AIUR_GITHUB_REQUESTS_PER_MINUTE", github_budget.requests_per_minute |> Integer.to_string() |> String.to_charlist()},
      {~c"AIUR_GITHUB_STAGGER_MS", github_budget.stagger_ms |> Integer.to_string() |> String.to_charlist()},
      {~c"AIUR_GITHUB_CORE_LIMIT_PER_HOUR", github_budget.agent_core_limit_per_hour |> Integer.to_string() |> String.to_charlist()},
      {~c"AIUR_GITHUB_GRAPHQL_LIMIT_PER_HOUR", github_budget.agent_graphql_limit_per_hour |> Integer.to_string() |> String.to_charlist()},
      {~c"AIUR_GITHUB_SEARCH_LIMIT_PER_HOUR", github_budget.agent_search_limit_per_hour |> Integer.to_string() |> String.to_charlist()}
    ]
  end

  @impl true
  def shell_exports(workspace, opts) do
    label_prefix = configured_label_prefix(opts)
    agent_bin = AgentGitHubGuard.bin_dir(workspace)
    github_budget = Budget.guard_settings()

    "AIUR_REAL_GH=\nexport AIUR_REAL_GH\n" <>
      "export AIUR_GITHUB_LABEL_PREFIX=#{Aiur.Shell.escape(label_prefix)}\n" <>
      remote_repo_slug_export() <>
      agent_comment_marker_export() <>
      "export AIUR_AGENT_BIN=#{Aiur.Shell.escape(agent_bin)}\n" <>
      "export GH_CONFIG_DIR=#{Aiur.Shell.escape(AgentGitHubGuard.gh_config_dir(workspace))}\n" <>
      "export AIUR_AGENT_QUOTA_STATE_PATH=#{Aiur.Shell.escape(AgentGitHubGuard.quota_dir(workspace))}\n" <>
      TestRunIsolation.remote_github_budget_exports() <>
      "unset AIUR_GITHUB_BUDGET_KEY\n" <>
      publication_credential_export(opts) <>
      "export AIUR_GITHUB_BUDGET_BROKER=#{Aiur.Shell.escape(AgentGitHubGuard.budget_broker_path(workspace))}\n" <>
      "export AIUR_GITHUB_BUDGET_CONSUMER=#{Aiur.Shell.escape("workspace:#{workspace}")}\n" <>
      "export AIUR_GITHUB_MAX_INFLIGHT=#{github_budget.max_inflight}\n" <>
      "export AIUR_GITHUB_MAX_INFLIGHT_PER_ENDPOINT=#{github_budget.max_inflight_per_endpoint}\n" <>
      "export AIUR_GITHUB_REQUESTS_PER_MINUTE=#{github_budget.requests_per_minute}\n" <>
      "export AIUR_GITHUB_STAGGER_MS=#{github_budget.stagger_ms}\n" <>
      "export AIUR_GITHUB_CORE_LIMIT_PER_HOUR=#{github_budget.agent_core_limit_per_hour}\n" <>
      "export AIUR_GITHUB_GRAPHQL_LIMIT_PER_HOUR=#{github_budget.agent_graphql_limit_per_hour}\n" <>
      "export AIUR_GITHUB_SEARCH_LIMIT_PER_HOUR=#{github_budget.agent_search_limit_per_hour}\n"
  end

  @impl true
  def repo_slug do
    case GitHubConfig.repo() do
      repo when is_binary(repo) and repo != "" -> repo
      _unconfigured -> nil
    end
  end

  @impl true
  def agent_process_log_path do
    case repo_slug() do
      nil -> nil
      repo -> repo |> Paths.repo_state_path() |> Path.join("github-quota/agent-processes.tsv")
    end
  end

  defp publication_credential_key(opts) do
    %Credential{id: "primary", kind: :machine_user, identity: publication_credential_identity(opts)}
    |> Credential.identity_key()
  end

  defp publication_credential_identity(opts) do
    Keyword.get_lazy(opts, :github_budget_identity, &GitHubConfig.bot_account/0)
  rescue
    _unavailable -> nil
  catch
    :exit, _reason -> nil
  end

  defp publication_credential_export(opts) do
    "export AIUR_GITHUB_BUDGET_IDENTITY_KEY=#{Aiur.Shell.escape(publication_credential_key(opts))}\n"
  end

  # `false` unsets the variable for the child, which is what a non-GitHub
  # tracker or an unconfigured repo should produce: the guard then resolves no
  # resource identity and caches nothing, rather than filing responses under a
  # placeholder slug that no other agent would ever ask for.
  # Remote workers keep their own budget root under their own home, so they get
  # their own state cache shared with the other agents on that host — the same
  # sharing boundary the budget broker already draws.
  defp remote_repo_slug_export do
    case configured_repo_slug() do
      false -> "unset AIUR_GITHUB_REPO\n"
      slug -> "export AIUR_GITHUB_REPO=#{Aiur.Shell.escape(List.to_string(slug))}\n"
    end
  end

  defp agent_comment_marker do
    if GitHubConfig.single_account?(), do: String.to_charlist(AgentMarker.marker()), else: false
  end

  defp agent_comment_marker_export do
    case agent_comment_marker() do
      false ->
        "unset #{AgentMarker.env_var()}\n"

      marker ->
        "export #{AgentMarker.env_var()}=#{Aiur.Shell.escape(List.to_string(marker))}\n"
    end
  end

  defp configured_repo_slug do
    case GitHubConfig.repo() do
      repo when is_binary(repo) -> if repo =~ ~r{\A[\w.-]+/[\w.-]+\z}, do: String.to_charlist(repo), else: false
      _other -> false
    end
  end

  defp configured_label_prefix(opts), do: Keyword.get_lazy(opts, :label_prefix, &GitHubConfig.label_prefix/0)
end
