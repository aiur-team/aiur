defmodule Aiur.AgentEnvironment do
  @moduledoc """
  Helpers for preparing child agent process environments.
  """

  alias Aiur.{AgentBuildGuard, AgentGitHubGuard, AgentScratch, BuildGate, Config, RepoBase}
  alias Aiur.GitHub.{Budget, Credential}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Workspace.Remote

  # AIUR_RELEASE_NODE + AIUR_INSTANCE_KEY + AIUR_REPO_ROOT are the per-instance
  # identity inputs the engine exports (#431). They MUST be scrubbed too, or an agent
  # (codex inherits all env) leaks the outer instance's keyed identity into an inner
  # `aiurdev` it launches, which then reuses the outer's node/session and reaps the
  # live outer run. AIUR_REPO_ROOT is the root the key is hashed from — if it leaks the
  # inner recomputes the *outer's* key, so scrub it too (defense in depth: the dev shim
  # does not export it today, but any wrapping harness might).
  @erlang_distribution_env_names ~w(ERL_AFLAGS ERL_LIBS RELEASE_NODE RELEASE_COOKIE AIUR_RELEASE_NODE AIUR_INSTANCE_KEY AIUR_REPO_ROOT)
  @daemon_dump_env_names ~w(ERL_CRASH_DUMP ERL_CRASH_DUMP_SECONDS)
  @aiur_distribution_env_pattern ~r/\AAIUR(?:_.*)?_(?:NODE_NAME|COOKIE)\z/
  # `aiurdev` exports AIUR_RESTART_BUILD_CMD for the duration of an `aiur restart`
  # so the engine can run this checkout's rebuild between the stop and the start.
  # It is a command line bound to one checkout: inherited by an agent, an inner
  # `aiur restart` would run the OUTER checkout's builder against whatever
  # release it is pointed at. The receipt path is per-invocation for the same
  # reason — a stale one would let a later restart read a rebuild that is not its
  # own.
  @restart_build_env_names ~w(AIUR_RESTART_BUILD_CMD AIUR_RESTART_BUILD_RECEIPT AIUR_RESTART_BUILD_VERIFIES)
  @parent_log_env_names ~w(AIUR_LOGS_ROOT AIUR_AGENT_IR_LOGS_PARENT)
  @operator_only_env_names ~w(AIUR_CI_READINESS_TOKEN)
  @provider_credential_env_names ~w(DEEPSEEK_API_KEY MOONSHOT_API_KEY OPENROUTER_API_KEY OPENROUTER_MANAGEMENT_KEY)
  @provider_api_key_pattern ~r/_API_KEY\z/
  # The GitHub App credentials are the DAEMON's identity (#2266). Agents publish
  # as the bot account and carry its `GITHUB_TOKEN` PAT; the App installation is
  # deliberately a different login (see `AgentGitHubGuard`), and it is the
  # branch-protection bypass actor. An agent holding the App id, installation id
  # and private key can mint its own installation token, which passes through
  # neither `Aiur.GitHub.Transport` (so `Quota` never sees it) nor the `gh` guard
  # (so no `admissions` row exists) — unmetered spend against the App's GraphQL
  # pool. Scrubbed by prefix rather than by name so a credential added later
  # (`GITHUB_APP_CLIENT_SECRET`, …) is covered the day it is introduced.
  @app_credential_env_names ~w(GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY GITHUB_APP_PRIVATE_KEY_PATH)
  @app_credential_env_pattern ~r/\AGITHUB_APP_/
  @scheduler_option ~r/(^|\s)\+S\s+\d+(?::\d+)?/
  @neutral_zdotdir "/dev/null"

  @spec erlang_distribution_env_name?(String.t()) :: boolean()
  def erlang_distribution_env_name?(name) when is_binary(name) do
    name in @erlang_distribution_env_names or Regex.match?(@aiur_distribution_env_pattern, name)
  end

  @spec scrub_shell_command(String.t(), keyword()) :: String.t()
  def scrub_shell_command(command, opts \\ []) when is_binary(command) do
    exec_prefix = if Keyword.get(opts, :exec, false), do: "exec ", else: ""
    "#{shell_startup_prefix(opts)}; #{scrub_shell_prefix()}; #{exec_prefix}#{command}"
  end

  @doc """
  Startup-file suppression for every shell that Aiur starts on an agent's
  behalf. These values are deliberately applied at the process boundary, before
  the shell gets a chance to interpret an operator-controlled startup variable.
  """
  @spec shell_startup_env() :: [{String.t(), String.t() | false}]
  def shell_startup_env, do: [{"BASH_ENV", false}, {"ENV", false}, {"ZDOTDIR", @neutral_zdotdir}]

  @spec shell_startup_env_name?(String.t() | charlist()) :: boolean()
  def shell_startup_env_name?(name) when is_binary(name),
    do: Enum.any?(shell_startup_env(), fn {startup_name, _value} -> startup_name == name end)

  def shell_startup_env_name?(name) when is_list(name),
    do: shell_startup_env_name?(List.to_string(name))

  def shell_startup_env_name?(_name), do: false

  @doc """
  Same suppression as `shell_startup_env/0`, in the shape `System.cmd/3`
  accepts. `System.cmd` spells "remove this variable" as `nil`; `Port.open`
  and tmux spell it `false`. Passing `false` to `System.cmd` raises a
  `FunctionClauseError` inside `System.validate_env/1`.
  """
  @spec system_shell_startup_env() :: [{String.t(), String.t() | nil}]
  def system_shell_startup_env do
    Enum.map(shell_startup_env(), fn
      {name, false} -> {name, nil}
      {name, value} -> {name, value}
    end)
  end

  @spec port_shell_startup_env() :: [{charlist(), charlist() | false}]
  def port_shell_startup_env do
    Enum.map(shell_startup_env(), fn
      {name, false} -> {String.to_charlist(name), false}
      {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  @spec shell_startup_prefix(keyword()) :: String.t()
  def shell_startup_prefix(opts \\ []) do
    unset_names = if Keyword.get(opts, :trusted_bash_env, false), do: "ENV", else: "BASH_ENV ENV"
    "unset #{unset_names}; export ZDOTDIR=#{Aiur.Shell.escape(@neutral_zdotdir)}"
  end

  @spec scrub_shell_prefix() :: String.t()
  def scrub_shell_prefix do
    ("unset " <>
       Enum.join(
         @erlang_distribution_env_names ++
           @daemon_dump_env_names ++
           @restart_build_env_names ++
           @parent_log_env_names ++
           @operator_only_env_names ++ @provider_credential_env_names ++ @app_credential_env_names,
         " "
       ) <>
       "; ") <>
      "for aiur_env_name in $(env | sed 's/=.*//'); do " <>
      "case \"$aiur_env_name\" in " <>
      "AIUR_NODE_NAME|AIUR_*_NODE_NAME|AIUR_COOKIE|AIUR_*_COOKIE|*_API_KEY|GITHUB_APP_*) unset \"$aiur_env_name\" ;; " <>
      "esac; " <>
      "done; " <>
      release_launcher_scrub_prefix() <> "\n" <> agent_bin_scrub_prefix()
  end

  defp release_launcher_scrub_prefix do
    String.trim(~S"""
    aiur_release_root=${AIUR_RELEASE_DIR%/}
    if [ -n "$aiur_release_root" ]; then
      # ROOTDIR/BINDIR/EMU/PROGNAME are scrubbed independently, and only when
      # their value is canonical for the release. EMU/PROGNAME carry the generic
      # values `beam`/`erl` that any toolchain could set, so they are
      # release-owned only when the launcher boundary (ROOTDIR or BINDIR) is
      # actually in force; otherwise a user's unrelated EMU/PROGNAME would be
      # dropped too.
      aiur_launcher_owned=
      if [ "${ROOTDIR:-}" = "$aiur_release_root" ]; then unset ROOTDIR; aiur_launcher_owned=1; fi
      aiur_bindir=${BINDIR:-}
      aiur_bindir=${aiur_bindir%/}
      case "$aiur_bindir" in "$aiur_release_root"/erts-*/bin) unset BINDIR; aiur_launcher_owned=1 ;; esac
      unset aiur_bindir
      if [ -n "$aiur_launcher_owned" ]; then
        [ "${EMU:-}" = beam ] && unset EMU
        [ "${PROGNAME:-}" = erl ] && unset PROGNAME
      fi

      # Filter release bin/erts-*-bin PATH entries regardless of launcher-var
      # ownership. Each entry is compared with a trailing slash stripped so a
      # `.../bin/` entry cannot leak a release ERTS onto the child PATH.
      aiur_remaining_path=${PATH-}
      aiur_clean_path=
      aiur_path_separator=
      while :; do
        case "$aiur_remaining_path" in
          *:*) aiur_path_entry=${aiur_remaining_path%%:*}; aiur_remaining_path=${aiur_remaining_path#*:}; aiur_path_more=1 ;;
          *) aiur_path_entry=$aiur_remaining_path; aiur_path_more= ;;
        esac
        aiur_path_norm=${aiur_path_entry%/}
        case "$aiur_path_norm" in
          "$aiur_release_root/bin"|"$aiur_release_root"/erts-*/bin) ;;
          *) aiur_clean_path="${aiur_clean_path}${aiur_path_separator}${aiur_path_entry}"; aiur_path_separator=: ;;
        esac
        [ -n "$aiur_path_more" ] || break
      done
      PATH=$aiur_clean_path
      export PATH
    fi
    unset aiur_release_root aiur_remaining_path aiur_clean_path aiur_path_separator aiur_path_entry aiur_path_more aiur_path_norm aiur_launcher_owned
    """)
  end

  defp agent_bin_scrub_prefix do
    String.trim(~S"""
    if [ -n "${AIUR_AGENT_BIN:-}" ]; then
      PATH="$AIUR_AGENT_BIN:$PATH"
      export PATH
    fi
    if [ -n "${AIUR_BUILD_GATE_BIN:-}" ]; then
      PATH="$AIUR_BUILD_GATE_BIN:$PATH"
      export PATH
    fi
    """)
  end

  @spec parent_log_env_name?(String.t()) :: boolean()
  def parent_log_env_name?(name) when is_binary(name), do: name in @parent_log_env_names

  @doc false
  @spec provider_credential_env_names() :: [String.t()]
  def provider_credential_env_names do
    inherited = System.get_env() |> Map.keys() |> Enum.filter(&Regex.match?(@provider_api_key_pattern, &1))
    Enum.uniq(@provider_credential_env_names ++ inherited)
  end

  @doc """
  Every GitHub App credential variable to remove from an agent's environment:
  the known names plus anything the daemon inherited under the same
  `GITHUB_APP_` prefix. See the attribute comment for why agents must not hold
  these (#2266).
  """
  @spec app_credential_env_names() :: [String.t()]
  def app_credential_env_names do
    inherited = System.get_env() |> Map.keys() |> Enum.filter(&Regex.match?(@app_credential_env_pattern, &1))
    Enum.uniq(@app_credential_env_names ++ inherited)
  end

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
        @erlang_distribution_env_names ++
          @daemon_dump_env_names ++
          @restart_build_env_names ++
          @parent_log_env_names ++
          @operator_only_env_names ++
          provider_credential_env_names() ++ app_credential_env_names() ++ ["AIUR_GITHUB_BUDGET_KEY"],
        fn name -> {String.to_charlist(name), false} end
      )

    port_startup_env =
      shell_startup_env()
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
        {~c"AIUR_AGENT_QUOTA_STATE_PATH", workspace |> Path.join(".aiur-runtime/github-quota") |> String.to_charlist()},
        {~c"AIUR_AGENT_BIN", workspace |> AgentGitHubGuard.bin_dir() |> String.to_charlist()},
        # SECURITY INVARIANT — see `AgentGitHubGuard.gh_config_dir/1`. An empty
        # agent-private `gh` config dir severs the operator keyring, which is
        # the identity that can bypass branch protection. Removing this makes
        # `env -u GITHUB_TOKEN -u GH_TOKEN gh pr review --approve` succeed as
        # the human again.
        {~c"GH_CONFIG_DIR", workspace |> AgentGitHubGuard.gh_config_dir() |> String.to_charlist()},
        {~c"AIUR_REAL_GH", if(real_gh, do: String.to_charlist(real_gh), else: false)},
        {~c"AIUR_GITHUB_LABEL_PREFIX", String.to_charlist(label_prefix)},
        # The repository the agent was dispatched against, so the `gh` guard can
        # file a cached response under a resource identity (#2073 U6). `gh`
        # resolves the repo from the working directory, so the guard only trusts
        # this while the agent is inside the workspace below — a clone of some
        # other repository must not have its answers filed under this one.
        {~c"AIUR_GITHUB_REPO", configured_repo_slug()},
        {~c"AIUR_GITHUB_BUDGET_ROOT", Budget.state_dir() |> String.to_charlist()},
        {~c"AIUR_GITHUB_BUDGET_BROKER", workspace |> AgentGitHubGuard.budget_broker_path() |> String.to_charlist()},
        {~c"AIUR_GITHUB_BUDGET_CONSUMER", "workspace:#{workspace}" |> String.to_charlist()},
        {~c"AIUR_GITHUB_BUDGET_IDENTITY_KEY", publication_credential_key(opts) |> String.to_charlist()},
        {~c"AIUR_GITHUB_MAX_INFLIGHT", github_budget.max_inflight |> Integer.to_string() |> String.to_charlist()},
        {~c"AIUR_GITHUB_MAX_INFLIGHT_PER_ENDPOINT", github_budget.max_inflight_per_endpoint |> Integer.to_string() |> String.to_charlist()},
        {~c"AIUR_GITHUB_REQUESTS_PER_MINUTE", github_budget.requests_per_minute |> Integer.to_string() |> String.to_charlist()},
        {~c"AIUR_GITHUB_STAGGER_MS", github_budget.stagger_ms |> Integer.to_string() |> String.to_charlist()},
        {~c"AIUR_GITHUB_CORE_LIMIT_PER_HOUR", github_budget.agent_core_limit_per_hour |> Integer.to_string() |> String.to_charlist()},
        {~c"AIUR_GITHUB_GRAPHQL_LIMIT_PER_HOUR", github_budget.agent_graphql_limit_per_hour |> Integer.to_string() |> String.to_charlist()},
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
  # just the paths someone remembered to make unique; TMP/TEMP follow it so tools
  # reading those land in the same place.
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
      [{~c"TMPDIR", value}, {~c"TMP", value}, {~c"TEMP", value}]
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
      "export AIUR_AGENT_BIN=#{Aiur.Shell.escape(agent_bin)}\n" <>
      "export GH_CONFIG_DIR=#{Aiur.Shell.escape(AgentGitHubGuard.gh_config_dir(workspace))}\n" <>
      "export AIUR_AGENT_QUOTA_STATE_PATH=#{Aiur.Shell.escape(Path.join(workspace, ".aiur-runtime/github-quota"))}\n" <>
      "export AIUR_AGENT_WORKSPACE=#{Aiur.Shell.escape(workspace)}\n" <>
      "export AIUR_GITHUB_BUDGET_ROOT='~/.aiur/github-budget'\n" <>
      "AIUR_GITHUB_BUDGET_ROOT=\"$HOME/${AIUR_GITHUB_BUDGET_ROOT#\\~/}\"\nexport AIUR_GITHUB_BUDGET_ROOT\n" <>
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
      "aiur_scratch_dir=#{Aiur.Shell.escape(AgentScratch.dir(workspace))}\n" <>
      "if mkdir -p \"$aiur_scratch_dir\" 2>/dev/null; then\n" <>
      ~s(  TMPDIR="$aiur_scratch_dir"; TMP="$aiur_scratch_dir"; TEMP="$aiur_scratch_dir"\n) <>
      "  export TMPDIR TMP TEMP\nfi\nunset aiur_scratch_dir\n" <>
      "{ #{scrub_shell_prefix()}; } && " <>
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
