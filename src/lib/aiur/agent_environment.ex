defmodule Aiur.AgentEnvironment do
  @moduledoc """
  Helpers for preparing child agent process environments.
  """

  alias Aiur.{BuildGate, Config, RepoBase}
  alias Aiur.Workspace.Remote

  # AIUR_RELEASE_NODE + AIUR_INSTANCE_KEY + AIUR_REPO_ROOT are the per-instance
  # identity inputs the engine exports (#431). They MUST be scrubbed too, or an agent
  # (codex inherits all env) leaks the outer instance's keyed identity into an inner
  # `aiurdev` it launches, which then reuses the outer's node/session and reaps the
  # live outer run. AIUR_REPO_ROOT is the root the key is hashed from — if it leaks the
  # inner recomputes the *outer's* key, so scrub it too (defense in depth: the dev shim
  # does not export it today, but any wrapping harness might).
  @erlang_distribution_env_names ~w(ERL_AFLAGS RELEASE_NODE RELEASE_COOKIE AIUR_RELEASE_NODE AIUR_INSTANCE_KEY AIUR_REPO_ROOT)
  @aiur_distribution_env_pattern ~r/\AAIUR(?:_.*)?_(?:NODE_NAME|COOKIE)\z/
  @parent_log_env_names ~w(AIUR_LOGS_ROOT AIUR_AGENT_IR_LOGS_PARENT)
  @operator_only_env_names ~w(AIUR_CI_READINESS_TOKEN)
  @provider_credential_env_names ~w(DEEPSEEK_API_KEY MOONSHOT_API_KEY OPENROUTER_API_KEY OPENROUTER_MANAGEMENT_KEY)
  @provider_api_key_pattern ~r/_API_KEY\z/
  @scheduler_option ~r/(^|\s)\+S\s+\d+(?::\d+)?/
  @neutral_zdotdir "/dev/null"

  @spec erlang_distribution_env_name?(String.t()) :: boolean()
  def erlang_distribution_env_name?(name) when is_binary(name) do
    name in @erlang_distribution_env_names or Regex.match?(@aiur_distribution_env_pattern, name)
  end

  @spec scrub_shell_command(String.t(), keyword()) :: String.t()
  def scrub_shell_command(command, opts \\ []) when is_binary(command) do
    exec_prefix = if Keyword.get(opts, :exec, false), do: "exec ", else: ""
    "#{shell_startup_prefix()}; #{scrub_shell_prefix()}; #{exec_prefix}#{command}"
  end

  @doc """
  Startup-file suppression for every shell that Aiur starts on an agent's
  behalf. These values are deliberately applied at the process boundary, before
  the shell gets a chance to interpret an operator-controlled startup variable.
  """
  @spec shell_startup_env() :: [{String.t(), String.t() | false}]
  def shell_startup_env, do: [{"BASH_ENV", false}, {"ENV", false}, {"ZDOTDIR", @neutral_zdotdir}]

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

  @spec shell_startup_prefix() :: String.t()
  def shell_startup_prefix, do: "unset BASH_ENV ENV; export ZDOTDIR=#{Aiur.Shell.escape(@neutral_zdotdir)}"

  @spec scrub_shell_prefix() :: String.t()
  def scrub_shell_prefix do
    ("unset " <>
       Enum.join(
         @erlang_distribution_env_names ++
           @parent_log_env_names ++ @operator_only_env_names ++ @provider_credential_env_names,
         " "
       ) <>
       "; ") <>
      "for aiur_env_name in $(env | sed 's/=.*//'); do " <>
      "case \"$aiur_env_name\" in " <>
      "AIUR_NODE_NAME|AIUR_*_NODE_NAME|AIUR_COOKIE|AIUR_*_COOKIE|*_API_KEY) unset \"$aiur_env_name\" ;; " <>
      "esac; " <>
      "done; " <>
      release_launcher_scrub_prefix()
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

  @spec parent_log_env_name?(String.t()) :: boolean()
  def parent_log_env_name?(name) when is_binary(name), do: name in @parent_log_env_names

  @doc false
  @spec provider_credential_env_names() :: [String.t()]
  def provider_credential_env_names do
    inherited = System.get_env() |> Map.keys() |> Enum.filter(&Regex.match?(@provider_api_key_pattern, &1))
    Enum.uniq(@provider_credential_env_names ++ inherited)
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
    {hex, mix, npm_cache} = sidecar_paths(opts)
    state_path = repo_url(opts) |> RepoBase.repo_path()
    base_branch = configured_base_branch(opts)

    unset_inherited_env =
      Enum.map(@parent_log_env_names ++ @operator_only_env_names ++ provider_credential_env_names(), fn name ->
        {String.to_charlist(name), false}
      end)

    shell_startup_env =
      shell_startup_env()
      |> replace_bash_env(BuildGate.shell_env())
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
        Enum.map(mix_scheduler_env(), fn {name, value} ->
          {String.to_charlist(name), String.to_charlist(value)}
        end) ++
        shell_startup_env

    unset_inherited_env ++ workspace_env
  end

  def workspace_env(_, _opts), do: []

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

    "{\n#{sidecar_exports}\n{ #{scrub_shell_prefix()}; } && " <>
      "export MISE_TRUSTED_CONFIG_PATHS=#{Aiur.Shell.escape(workspace)} " <>
      "AIUR_BASE_BRANCH=#{Aiur.Shell.escape(base_branch)} #{scheduler_exports}\n}"
  end

  def workspace_env_export_prefix(_, _opts), do: ""

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

  defp configured_base_branch(opts) do
    case Keyword.fetch(opts, :base_branch) do
      {:ok, branch} when is_binary(branch) and branch != "" -> branch
      _ -> Config.base_branch()
    end
  end

  defp sidecar_paths(opts) do
    root = repo_url(opts) |> RepoBase.repo_path()

    {Path.join(root, ".aiur-hex"), Path.join(root, ".aiur-mix"), Path.join(root, ".aiur-npm-cache")}
  end

  # Remote workers have their own home directories, so shell launches must
  # transmit a stable, home-relative state-node identity rather than the
  # daemon host's absolute cache path.
  defp remote_sidecar_paths(opts) do
    root = Path.join("~", RepoBase.repo_relative_path(repo_url(opts)))

    {Path.join(root, ".aiur-hex"), Path.join(root, ".aiur-mix"), Path.join(root, ".aiur-npm-cache")}
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
