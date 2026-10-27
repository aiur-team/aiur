defmodule Aiur.AgentEnvironment.WorkspaceEnv do
  @moduledoc false

  alias Aiur.{AgentBuildGuard, AgentScratch, BuildGate, Config, Shell}
  alias Aiur.AgentEnvironment.{Contributor, CredentialScrub, GitHubPath, GitIdentity, Names, SchedulerOptions, ShellScrub}
  alias Aiur.Config.Paths

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
    state_path = repo_url(opts) |> Paths.repo_state_path()
    base_branch = configured_base_branch(opts)
    build_gate_env = BuildGate.shell_env()
    real_git = System.find_executable("git")

    unset_inherited_env =
      Enum.map(
        Names.erlang_distribution() ++
          Names.daemon_dump() ++
          ~w(AIUR_BUILD_GATE_LEASE_PATH AIUR_BUILD_GATE_LEASE_TOKEN) ++
          Names.restart_build() ++
          Names.parent_log() ++
          Names.operator_only() ++
          Aiur.AgentEnvironment.provider_credential_env_names() ++
          Aiur.AgentEnvironment.app_credential_env_names() ++
          CredentialScrub.remote_instance_token_env_names() ++
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
        {~c"AIUR_REAL_GIT", if(real_git, do: String.to_charlist(real_git), else: false)},
        # Trust the workspace ROOT so the repo's `mise.toml` is honored wherever it
        # lives (most repos — including aiur — keep it at the root, not under
        # `elixir/`). Mirrors `base_env/1` (#432); a sub-path assumption left the
        # actual config untrusted (#440).
        {~c"MISE_TRUSTED_CONFIG_PATHS", String.to_charlist(workspace)},
        # The tracker integration branch is authoritative for agent-created
        # pull requests. Keep it in the actual child process environment so PR
        # creation never falls back to the repository's different default.
        {~c"AIUR_BASE_BRANCH", String.to_charlist(base_branch)},
        # Marker so nested `scripts/aiurdev` calls can refuse destructive
        # commands (`--test`, `--test3`, `stop`) before touching the parent run.
        {~c"AIUR_AGENT_WORKSPACE", String.to_charlist(workspace)},
        # `aiur-claude` uses provider quota from a rate-limited endpoint. Match
        # its cache TTL to the configured polling cadence to avoid repeated 429s.
        {~c"AIUR_CLAUDE_USAGE_TTL_MS", String.to_charlist(usage_ttl_ms())}
      ] ++
        GitHubPath.port_env(workspace) ++
        scratch_env(workspace) ++
        GitIdentity.port_env(opts) ++
        Enum.map(mix_scheduler_env(), fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end) ++
        build_gate_bin_env(workspace, build_gate_env) ++
        port_startup_env ++
        Aiur.AgentShellHook.port_env(build_gate_env)

    contributions = Contributor.port_env(workspace, opts)

    contributed_credentials = for {name, _value} <- contributions, CredentialScrub.contributed_credential_name?(name), do: {name, false}

    (workspace_env ++ contributions ++ unset_inherited_env ++ contributed_credentials)
    |> Map.new()
    |> Map.to_list()
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

  # AgentShellHook replaces operator BASH_ENV, repairs PATH after profiles, then sources this hook.
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
    state_path = Path.join("~", Paths.repo_state_relative_path(repo_url(opts)))
    base_branch = configured_base_branch(opts)
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
          Shell.remote_assign(variable, path),
          "export #{variable}"
        ]
        |> Enum.join("\n")
      end)

    # Workspace-private scratch, so concurrent agents cannot clobber each
    # other's staged files through the shared host /tmp (#1763). The `mkdir`
    # covers workspaces provisioned before this existed; only redirect TMPDIR
    # when it succeeds, so an unwritable path leaves the launch working rather
    # than pointing every tool at a directory that is not there.
    "{\n#{sidecar_exports}\n#{build_gate_exports}" <>
      "AIUR_REAL_GIT=#{if real_git, do: Aiur.Shell.escape(real_git), else: ""}\nexport AIUR_REAL_GIT\n" <>
      Contributor.shell_exports(workspace, opts) <>
      "export AIUR_AGENT_WORKSPACE=#{Aiur.Shell.escape(workspace)}\n" <>
      GitHubPath.shell_export(workspace) <>
      GitIdentity.export_prefix(opts) <>
      "aiur_scratch_dir=#{Aiur.Shell.escape(AgentScratch.dir(workspace))}\n" <>
      "if mkdir -p \"$aiur_scratch_dir\" 2>/dev/null; then\n" <>
      ~s(  TMPDIR="$aiur_scratch_dir"; TMP="$aiur_scratch_dir"; TEMP="$aiur_scratch_dir"; TMPPREFIX="$aiur_scratch_dir/zsh-"\n) <>
      "  export TMPDIR TMP TEMP TMPPREFIX\nfi\nunset aiur_scratch_dir\n" <>
      "unset AIUR_GITHUB_BUDGET_KEY\n" <>
      "{ #{ShellScrub.scrub_shell_prefix()}; } && " <>
      "export MISE_TRUSTED_CONFIG_PATHS=#{Aiur.Shell.escape(workspace)} " <>
      "AIUR_BASE_BRANCH=#{Aiur.Shell.escape(base_branch)} #{scheduler_exports}\n}"
  end

  def workspace_env_export_prefix(_, _opts), do: ""

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
      "#{Shell.remote_assign(name, value)}\nexport #{name}\n"
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

  # The per-agent adapter keeps the operator's usage interval. The daemon's
  # direct probe may use a shorter cache cadence to honor the stale-reading
  # cutoff, but multiplying that cadence across agent processes would hammer
  # the endpoint. Falls back to the configured default when config is absent.
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
      {"ELIXIR_ERL_OPTIONS", SchedulerOptions.build(cap)}
    ]
  end

  defp build_gate_bin_env(_workspace, []), do: []

  defp build_gate_bin_env(workspace, _build_gate_env) do
    [{~c"AIUR_BUILD_GATE_BIN", workspace |> AgentBuildGuard.bin_dir() |> String.to_charlist()}]
  end

  defp configured_base_branch(opts), do: Config.base_branch(opts)

  @doc false
  @spec package_cache_paths(keyword()) :: [Path.t()]
  def package_cache_paths(opts \\ []) do
    root = repo_url(opts) |> Paths.repo_state_path()

    Paths.repo_cache_sidecar_paths(root)
  end

  # Remote workers have their own home directories, so shell launches must
  # transmit a stable, home-relative state-node identity rather than the
  # daemon host's absolute cache path.
  defp remote_sidecar_paths(opts) do
    root = Path.join("~", Paths.repo_state_relative_path(repo_url(opts)))

    root |> Paths.repo_cache_sidecar_paths() |> List.to_tuple()
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
      case Contributor.repo_slug() do
        repo when is_binary(repo) and repo != "" -> "https://github.com/#{repo}.git"
        _ -> neutral_repo_url()
      end
    end)
    |> case do
      url when is_binary(url) and url != "" -> url
      _ -> neutral_repo_url()
    end
  end
end
