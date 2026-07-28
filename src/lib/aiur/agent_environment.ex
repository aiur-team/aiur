defmodule Aiur.AgentEnvironment do
  @moduledoc """
  Helpers for preparing child agent process environments.
  """

  alias Aiur.{BuildGate, Config}

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
  @scheduler_option ~r/(^|\s)\+S\s+\d+(?::\d+)?/

  @spec erlang_distribution_env_name?(String.t()) :: boolean()
  def erlang_distribution_env_name?(name) when is_binary(name) do
    name in @erlang_distribution_env_names or Regex.match?(@aiur_distribution_env_pattern, name)
  end

  @spec scrub_shell_command(String.t(), keyword()) :: String.t()
  def scrub_shell_command(command, opts \\ []) when is_binary(command) do
    exec_prefix = if Keyword.get(opts, :exec, false), do: "exec ", else: ""
    "#{scrub_shell_prefix()}; #{exec_prefix}#{command}"
  end

  @spec scrub_shell_prefix() :: String.t()
  def scrub_shell_prefix do
    "unset ERL_AFLAGS RELEASE_NODE RELEASE_COOKIE AIUR_RELEASE_NODE AIUR_INSTANCE_KEY AIUR_REPO_ROOT " <>
      "AIUR_LOGS_ROOT AIUR_AGENT_IR_LOGS_PARENT; " <>
      "for aiur_env_name in $(env | sed 's/=.*//'); do " <>
      "case \"$aiur_env_name\" in " <>
      "AIUR_NODE_NAME|AIUR_*_NODE_NAME|AIUR_COOKIE|AIUR_*_COOKIE) unset \"$aiur_env_name\" ;; " <>
      "esac; " <>
      "done"
  end

  @spec parent_log_env_name?(String.t()) :: boolean()
  def parent_log_env_name?(name) when is_binary(name), do: name in @parent_log_env_names

  @doc """
  Return Port-compatible env tuples (`{charlist_name, charlist_value}`) for
  per-workspace `HEX_HOME` / `MIX_HOME` / `MISE_TRUSTED_CONFIG_PATHS` plus the
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
    hex = Path.join(workspace, ".aiur-hex")
    mix = Path.join(workspace, ".aiur-mix")
    base_branch = configured_base_branch(opts)

    unset_parent_logs =
      Enum.map(@parent_log_env_names, fn name ->
        {String.to_charlist(name), false}
      end)

    workspace_env =
      [
        {~c"HEX_HOME", String.to_charlist(hex)},
        {~c"MIX_HOME", String.to_charlist(mix)},
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
        Enum.map(BuildGate.shell_env(), fn {name, value} ->
          {String.to_charlist(name), String.to_charlist(value)}
        end)

    unset_parent_logs ++ workspace_env
  end

  def workspace_env(_, _opts), do: []

  @doc """
  Shell-export prefix for the same vars `workspace_env/1` injects into
  Port.open env. Used by the SSH-launch path which has no `env:` option
  available — exports are inlined into the remote bash command instead.
  """
  @spec workspace_env_export_prefix(any(), keyword()) :: String.t()
  def workspace_env_export_prefix(workspace, opts \\ [])

  def workspace_env_export_prefix(workspace, opts) when is_binary(workspace) do
    hex = Path.join(workspace, ".aiur-hex")
    mix = Path.join(workspace, ".aiur-mix")
    base_branch = configured_base_branch(opts)

    # Trust the workspace ROOT (see `workspace_env/1`): the SSH-launch path needs
    # the same root-level trust so mise-provided tools resolve in the workspace.
    scheduler_exports =
      mix_scheduler_env()
      |> Enum.map_join(" ", fn {name, value} -> "#{name}=#{Aiur.Shell.escape(value)}" end)

    "export HEX_HOME=#{Aiur.Shell.escape(hex)} MIX_HOME=#{Aiur.Shell.escape(mix)} " <>
      "MISE_TRUSTED_CONFIG_PATHS=#{Aiur.Shell.escape(workspace)} " <>
      "AIUR_BASE_BRANCH=#{Aiur.Shell.escape(base_branch)} #{scheduler_exports}"
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
  @default_usage_interval_seconds 60

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

  defp scheduler_options(cap) do
    System.get_env("ELIXIR_ERL_OPTIONS", "")
    |> then(&Regex.replace(@scheduler_option, &1, ""))
    |> String.split()
    |> Kernel.++(["+S", "#{cap}:#{cap}"])
    |> Enum.join(" ")
  end
end
