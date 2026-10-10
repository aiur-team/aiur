defmodule Aiur.AgentEnvironment.WorkspaceEnv do
  @moduledoc false

  alias Aiur.{AgentBuildGuard, AgentGitHubGuard, AgentScratch, BuildGate, Config, RepoBase}
  alias Aiur.AgentEnvironment.{Names, ShellScrub}
  alias Aiur.GitHub.{AgentMarker, Budget, Credential}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Workspace.Remote

  @scheduler_option ~r/(^|\s)\+S\s+\d+(?::\d+)?/

  @doc """
  Return Port-compatible env tuples (`{charlist_name, charlist_value}`) for
  repository-node `HEX_HOME` / `MIX_HOME` / `MISE_TRUSTED_CONFIG_PATHS` plus the
  workflow's authoritative `AIUR_BASE_BRANCH`. The agent inherits these so it
  does not redeclare them as inline prefixes on every
  `mix`/`mise` invocation (logs showed 48+ instances of agents inventing
  variant paths like `/tmp/aiur-100-hex`, `/tmp/aiur-hex`, `/tmp/hex-100`
  across one session — wasting 20-30s per agent on env+trust setup).

  Returns an empty list when `workspace` is not a binary so callers can splat
  the result into Port.open env opts unconditionally.
  """
  @spec workspace_env(any(), keyword()) :: [{charlist(), charlist() | false}]
  def workspace_env(workspace, opts \\ [])

  def workspace_env(workspace, opts) when is_binary(workspace) do
    [hex, mix, npm_cache] = package_cache_paths(opts)
    state_path = repo_url(opts) |> RepoBase.repo_path()
    base_branch = configured_base_branch(opts)
    label_prefix = configured_label_prefix(opts)
    real_gh = AgentGitHubGuard.real_gh()
    github_budget = Budget.guard_settings()
    build_gate_env = BuildGate.shell_env()
    real_git = System.find_executable("git")

    unset_inherited_env =
      Enum.map(
        Names.erlang_distribution() ++
          Names.daemon_dump() ++
          Names.restart_build() ++
          Names.parent_log() ++
          Names.operator_only() ++
          Aiur.AgentEnvironment.provider_credential_env_names() ++
          Aiur.AgentEnvironment.app_credential_env_names() ++
          Names.github_credential() ++
          ["AIUR_GITHUB_BUDGET_KEY"],
        fn name -> {String.to_charlist(name), false} end
      )

    port_startup_env =
      ShellScrub.shell_startup_env()
      |> replace_bash_env(build_gate_env)
      |> Enum.map(fn
        {name, false} -> {String.to_charlist(name), false}
        {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
      end)

    workspace_env =
      [
        {~c"HEX_HOME", String.to_charlist(hex)},
        {~c"MIX_HOME", String.to_charlist(mix)},
        {~c"npm_config_cache", String.to_charlist(npm_cache)},
        {~c"AIUR_REPO_STATE_PATH", String.to_charlist(state_path)},
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
        {~c"AIUR_GITHUB_SEARCH_LIMIT_PER_HOUR", github_budget.agent_search_limit_per_hour |> Integer.to_string() |> String.to_charlist()},
        {~c"AIUR_REAL_GIT", if(real_git, do: String.to_charlist(real_git), else: false)},
        # Trust the workspace ROOT so the repo's `mise.toml` is honored wherever it
        # lives (most repos — including aiur — keep it at the root, not under
        # `elixir/`). Mirrors `base_env/1` (#432); a hardcoded sub-path pointed at
        # a file that does not exist and left the real config untrusted (#440).
        {~c"MISE_TRUSTED_CONFIG_PATHS", String.to_charlist(workspace)},
        # The tracker integration branch is authoritative for agent-created
        # pull requests. Keep it in the actual child process environment so PR
        # creation never falls back to the repository's different default.
        {~c"AIUR_BASE_BRANCH", String.to_charlist(base_branch)},
        # Marker so any nested invocation of `scripts/aiurdev` from inside
        # an agent's workspace can detect it is running under an agent
        # and refuse destructive commands (`--test`, `--test3`, `stop`).
        # Without this, agents that try "manual CLI verification" by
        # running `./scripts/aiurdev --test` reset the Executor’s sandbox
        # tickets and kill the parent BEAM mid-run.
        {~c"AIUR_AGENT_WORKSPACE", String.to_charlist(workspace)},
        # `aiur-claude` reads provider quota from `/api/oauth/usage`, which
        # rate-limits: asking per session and per in-turn event earns a 429, and
        # a 429 means no reading at all. Hand it the operator's configured usage
        # cadence so the adapter caches for exactly as long as the daemon waits
        # between observations, instead of the two picking separate rhythms.
        {~c"AIUR_CLAUDE_USAGE_TTL_MS", String.to_charlist(usage_ttl_ms())}
      ] ++
        scratch_env(workspace) ++
        Enum.map(mix_scheduler_env(), fn {name, value} ->
          {String.to_charlist(name), String.to_charlist(value)}
        end) ++
        build_gate_bin_env(workspace, build_gate_env) ++
        port_startup_env

    unset_inherited_env ++ workspace_env
  end

  def workspace_env(_, _opts), do: []

  # Concurrent agents share the host's /tmp. Two agents staging a comment body at
  # the same obvious path (`/tmp/wp_new.md`) silently clobber each other, and the
  # loser publishes the other ticket's workpad under its own comment id (#1763).
  # A workspace-private TMPDIR fixes that for every tool the agent launches, not
  # just the paths someone remembered to make unique; TMP/TEMP follow it for
  # ordinary tools, and TMPPREFIX keeps zsh heredocs in that same directory.
  #
  # Created here as well as at provisioning time so workspaces provisioned before
  # this existed get a usable scratch dir on their next launch. If it cannot be
  # created, leave TMPDIR alone rather than pointing every tool at a directory
  # that is not there.
  defp scratch_env(workspace) do
    scratch_dir = AgentScratch.dir(workspace)

    with :ok <- AgentScratch.install(workspace),
         true <- File.dir?(scratch_dir) do
      value = String.to_charlist(scratch_dir)
      zsh_prefix = scratch_dir |> Path.join("zsh-") |> String.to_charlist()
      [{~c"TMPDIR", value}, {~c"TMP", value}, {~c"TEMP", value}, {~c"TMPPREFIX", zsh_prefix}]
    else
      _unavailable -> []
    end
  end

  # Build admission is the sole permitted BASH_ENV hook in an agent workspace:
  # it is an Aiur-owned absolute path, replaces (rather than inherits) the
  # operator value, and is only present when admission is enabled.
  defp replace_bash_env(startup_env, build_gate_env) do
    case List.keyfind(build_gate_env, "BASH_ENV", 0) do
      {"BASH_ENV", _hook_path} ->
        Enum.reject(startup_env, fn {name, _value} -> name == "BASH_ENV" end) ++ build_gate_env

      nil ->
        startup_env ++ build_gate_env
    end
  end

  @doc """
  Shell-export prefix for the same vars `workspace_env/1` injects into
  Port.open env. Used by the SSH-launch path which has no `env:` option
  available — exports are inlined into the remote bash command instead.
  """
  @spec workspace_env_export_prefix(any(), keyword()) :: String.t()
  def workspace_env_export_prefix(workspace, opts \\ [])

  def workspace_env_export_prefix(workspace, opts) when is_binary(workspace) do
    {hex, mix, npm_cache} = remote_sidecar_paths(opts)
    state_path = Path.join("~", RepoBase.repo_relative_path(repo_url(opts)))
    base_branch = configured_base_branch(opts)
    label_prefix = configured_label_prefix(opts)
    agent_bin = AgentGitHubGuard.bin_dir(workspace)
    github_budget = Budget.guard_settings()
    build_gate_exports = build_gate_export_prefix(workspace, opts)
    real_git = System.find_executable("git")

    # Trust the workspace ROOT (see `workspace_env/1`): the SSH-launch path needs
    # the same root-level trust so mise-provided tools resolve in the workspace.
    scheduler_exports =
      mix_scheduler_env()
      |> Enum.map_join(" ", fn {name, value} -> "#{name}=#{Aiur.Shell.escape(value)}" end)

    sidecar_exports =
      [HEX_HOME: hex, MIX_HOME: mix, npm_config_cache: npm_cache, AIUR_REPO_STATE_PATH: state_path]
      |> Enum.map_join("\n", fn {name, path} ->
        variable = Atom.to_string(name)

        [
          Remote.remote_shell_assign(variable, path),
          "export #{variable}"
        ]
        |> Enum.join("\n")
      end)

    # Workspace-private scratch, so concurrent agents cannot clobber each
    # other's staged files through the shared host /tmp (#1763). The `mkdir`
    # covers workspaces provisioned before this existed; only redirect TMPDIR
    # when it succeeds, so an unwritable path leaves the launch working rather
    # than pointing every tool at a directory that is not there.
    "{\n#{sidecar_exports}\n#{build_gate_exports}AIUR_REAL_GH=\n" <>
      "AIUR_REAL_GIT=#{if real_git, do: Aiur.Shell.escape(real_git), else: ""}\n" <>
      "export AIUR_REAL_GH AIUR_REAL_GIT\n" <>
      "export AIUR_GITHUB_LABEL_PREFIX=#{Aiur.Shell.escape(label_prefix)}\n" <>
      remote_repo_slug_export() <>
      agent_comment_marker_export() <>
      "export AIUR_AGENT_BIN=#{Aiur.Shell.escape(agent_bin)}\n" <>
      "export GH_CONFIG_DIR=#{Aiur.Shell.escape(AgentGitHubGuard.gh_config_dir(workspace))}\n" <>
      "export AIUR_AGENT_QUOTA_STATE_PATH=#{Aiur.Shell.escape(AgentGitHubGuard.quota_dir(workspace))}\n" <>
      "export AIUR_AGENT_WORKSPACE=#{Aiur.Shell.escape(workspace)}\n" <>
      "export AIUR_GITHUB_BUDGET_ROOT='~/.aiur/github-budget'\n" <>
      "AIUR_GITHUB_BUDGET_ROOT=\"$HOME/${AIUR_GITHUB_BUDGET_ROOT#\\~/}\"\nexport AIUR_GITHUB_BUDGET_ROOT\n" <>
      "export AIUR_GITHUB_CREDENTIAL_FILE='~/.aiur/github-budget/agent-token'\n" <>
      "AIUR_GITHUB_CREDENTIAL_FILE=\"$HOME/${AIUR_GITHUB_CREDENTIAL_FILE#\\~/}\"\nexport AIUR_GITHUB_CREDENTIAL_FILE\n" <>
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
      "export AIUR_GITHUB_SEARCH_LIMIT_PER_HOUR=#{github_budget.agent_search_limit_per_hour}\n" <>
      "aiur_scratch_dir=#{Aiur.Shell.escape(AgentScratch.dir(workspace))}\n" <>
      "if mkdir -p \"$aiur_scratch_dir\" 2>/dev/null; then\n" <>
      ~s(  TMPDIR="$aiur_scratch_dir"; TMP="$aiur_scratch_dir"; TEMP="$aiur_scratch_dir"; TMPPREFIX="$aiur_scratch_dir/zsh-"\n) <>
      "  export TMPDIR TMP TEMP TMPPREFIX\nfi\nunset aiur_scratch_dir\n" <>
      "{ #{ShellScrub.scrub_shell_prefix()}; } && " <>
      "export MISE_TRUSTED_CONFIG_PATHS=#{Aiur.Shell.escape(workspace)} " <>
      "AIUR_BASE_BRANCH=#{Aiur.Shell.escape(base_branch)} #{scheduler_exports}\n}"
  end

  def workspace_env_export_prefix(_, _opts), do: ""

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

  defp build_gate_export_prefix(workspace, opts) do
    if Keyword.get(opts, :build_gate, false) do
      format_build_gate_exports(workspace, BuildGate.shell_env())
    else
      ""
    end
  end

  defp format_build_gate_exports(_workspace, []), do: ""

  defp format_build_gate_exports(workspace, build_gate_env) do
    [{"AIUR_BUILD_GATE_BIN", AgentBuildGuard.bin_dir(workspace)} | build_gate_env]
    |> Enum.map_join("", fn {name, value} ->
      "#{Remote.remote_shell_assign(name, value)}\nexport #{name}\n"
    end)
  end

  @doc """
  `System.cmd`-compatible env tuples (binary key/value) that trust the prewarm
  base checkout's `mise` config. `RepoBase` runs `base_build` in the freshly-
  cloned base dir; without this its `mise.toml` is untrusted and every
  mise-provided tool (pnpm, node, `mix` via `mise exec`) fails with
  "Config files ... are not trusted", so the base never builds. Trusts the base
  ROOT so the config is honored wherever the repo keeps it (root or sub-path).
  Returns `[]` for a non-binary arg so callers can splat into `System.cmd` env
  unconditionally.
  """
  @spec base_env(any()) :: [{String.t(), String.t()}]
  def base_env(base_path) when is_binary(base_path) do
    [{"MISE_TRUSTED_CONFIG_PATHS", base_path}]
  end

  def base_env(_), do: []

  # Mirrors `polling.usage_interval_seconds`, the same setting that paces
  # `Aiur.ProviderMeterRefresh`. Falls back to the scheduler's own default when
  # config is unavailable, so a mis-set config cannot make the adapter hammer
  # the endpoint.
  @default_usage_interval_seconds 300

  defp usage_ttl_ms do
    seconds =
      case Aiur.Config.settings() do
        {:ok, %{polling: %{usage_interval_seconds: value}}} when is_integer(value) and value > 0 -> value
        _unavailable -> @default_usage_interval_seconds
      end

    Integer.to_string(seconds * 1_000)
  rescue
    _error -> Integer.to_string(@default_usage_interval_seconds * 1_000)
  catch
    _kind, _reason -> Integer.to_string(@default_usage_interval_seconds * 1_000)
  end

  defp mix_scheduler_env do
    cap = Config.mix_scheduler_cap()

    [
      {"AIUR_AGENT_MIX_SCHEDULERS", Integer.to_string(cap)},
      {"ELIXIR_ERL_OPTIONS", scheduler_options(cap)}
    ]
  end

  defp build_gate_bin_env(_workspace, []), do: []

  defp build_gate_bin_env(workspace, _build_gate_env) do
    [{~c"AIUR_BUILD_GATE_BIN", workspace |> AgentBuildGuard.bin_dir() |> String.to_charlist()}]
  end

  defp configured_base_branch(opts), do: Config.base_branch(opts)
  defp configured_label_prefix(opts), do: Keyword.get_lazy(opts, :label_prefix, &GitHubConfig.label_prefix/0)

  @doc false
  @spec package_cache_paths(keyword()) :: [Path.t()]
  def package_cache_paths(opts \\ []) do
    root = repo_url(opts) |> RepoBase.repo_path()

    RepoBase.cache_sidecar_paths(root)
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

  # Remote workers have their own home directories, so shell launches must
  # transmit a stable, home-relative state-node identity rather than the
  # daemon host's absolute cache path.
  defp remote_sidecar_paths(opts) do
    root = Path.join("~", RepoBase.repo_relative_path(repo_url(opts)))

    root |> RepoBase.cache_sidecar_paths() |> List.to_tuple()
  end

  @doc """
  The neutral repo identity used when the configured tracker has no repository
  slug (Linear, memory, or other non-GitHub trackers). Sidecars and the state
  node path then resolve to a stable shared location under the state root
  instead of a per-workspace path, and hooks receive the same value as agents.
  """
  @spec neutral_repo_url() :: String.t()
  def neutral_repo_url, do: "unknown/unknown"

  defp repo_url(opts) do
    Keyword.get_lazy(opts, :repo_url, fn ->
      case Aiur.GitHub.Config.repo() do
        repo when is_binary(repo) and repo != "" -> "https://github.com/#{repo}.git"
        _ -> neutral_repo_url()
      end
    end)
    |> case do
      url when is_binary(url) and url != "" -> url
      _ -> neutral_repo_url()
    end
  end

  defp scheduler_options(cap) do
    System.get_env("ELIXIR_ERL_OPTIONS", "")
    |> then(&Regex.replace(@scheduler_option, &1, ""))
    |> String.split()
    |> Kernel.++(["+S", "#{cap}:#{cap}"])
    |> Enum.join(" ")
  end
end
