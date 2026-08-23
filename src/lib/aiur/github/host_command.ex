defmodule Aiur.GitHub.HostCommand do
  @moduledoc """
  Runs `gh` from host-side Elixir code through the budget guard wrapper.

  The daemon installs a guard wrapper at `~/.aiur/bin/gh`
  (`Aiur.AgentGitHubGuard.install_host/0`), but agent workspaces are the only
  place `gh` resolves to a wrapper through `PATH`. Host-side code that calls
  `System.cmd("gh", ...)` — the test reset, the init wizard, workspace teardown,
  the keyring checks — resolves the *real* `gh` instead, bypassing the broker
  entirely: every one of those calls is admitted to GitHub without an `admissions`
  row, and the ones that resolve the operator's keyring (when `GITHUB_TOKEN` is
  not exported to the child) spend the human's quota unattributed (#2353).

  This module is the one resolver for that host-side code. It prefers the guard
  wrapper when one is installed, so the call is admitted and recorded exactly as
  an agent's `gh` would be; `run/2` accepts `bot_token: true` to name the
  daemon's credential deliberately in the child environment, so a call that
  today falls through to the keyring authenticates as the bot instead.

  ## What this is not

  It does not wrap the operator's interactive shell. `~/.aiur/bin` has to be on
  an Executor shell's `PATH` for `gh pr review`/`gh pr merge` to reach the
  guard; this module covers the daemon's own programmatic calls, and the guard's
  identity binding (see `priv/github_quota_guard.sh`) covers whichever credential
  that shell resolves.
  """

  alias Aiur.AgentGitHubGuard
  alias Aiur.GitHub.Config, as: GitHubConfig

  @doc """
  The host `gh` executable to use for daemon-side calls.

  Prefers the installed guard wrapper so the call is admitted and recorded;
  falls back to the real `gh` on a host where the wrapper is not installed
  (tests, minimal installs). Returns `nil` when no `gh` resolves at all.

  Options:

    * `:wrapper_dir` — an explicit directory to look for the guard wrapper in,
      overriding the default `~/.aiur/bin`. Test seam; production callers leave
      it unset.
  """
  @spec find_executable(keyword()) :: String.t() | nil
  def find_executable(opts \\ []) do
    case installed_host_wrapper(Keyword.get(opts, :wrapper_dir)) do
      path when is_binary(path) -> path
      _missing -> System.find_executable("gh")
    end
  end

  @doc """
  Runs `gh` through the resolved executable, mirroring `System.cmd/3`.

  Options:

    * `:bot_token` — when `true`, injects the daemon's resolved token as
      `GH_TOKEN` in the child environment so the call authenticates as the
      daemon's credential instead of falling through to the operator's keyring.
      A literal token string is injected verbatim, which is how a caller that
      already holds the credential names it (and how tests stay deterministic).
      This is how a call site "names the credential deliberately" (#2353).
    * `:wrapper_dir` — the guard wrapper directory to prefer, as in
      `find_executable/1` (test seam).
    * any `System.cmd/3` option (`:stderr_to_stdout`, `:env`, `:cd`, ...).

  Returns `{output, status}` exactly like `System.cmd/3`; `{output, 127}` when
  no executable resolves, so callers that already handle a missing binary keep
  working.
  """
  @spec run([String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def run(args, opts \\ []) do
    {wrapper_dir, opts} = Keyword.pop(opts, :wrapper_dir)

    case find_executable(wrapper_dir: wrapper_dir) do
      nil ->
        {"", 127}

      path ->
        {bot_token, opts} = Keyword.pop(opts, :bot_token, false)
        env = child_env(bot_token, opts)
        opts = Keyword.put(opts, :env, env)
        System.cmd(path, args, opts)
    end
  end

  @doc """
  Resolves the daemon's credential token for a deliberately-named `gh` call.

  Returns `nil` when the daemon has no resolvable token, in which case the call
  should proceed without a token override (the guard will resolve whatever
  credential exists, exactly as it does today).
  """
  @spec bot_token() :: String.t() | nil
  def bot_token do
    GitHubConfig.token()
  rescue
    _unavailable -> nil
  catch
    :exit, _reason -> nil
  end

  defp child_env(false, opts), do: Keyword.get(opts, :env, [])

  defp child_env(true, opts), do: bot_token_env(opts, bot_token())

  defp child_env(token, opts) when is_binary(token) and token != "", do: bot_token_env(opts, token)

  defp child_env(_other, opts), do: Keyword.get(opts, :env, [])

  defp bot_token_env(opts, token) when is_binary(token) and token != "" do
    base = Keyword.get(opts, :env, [])

    # `gh` prefers `GH_TOKEN` over `GITHUB_TOKEN`, so one override is
    # enough; GITHUB_TOKEN is removed (nil) so a stale inherited parent
    # value cannot leak into the child and confuse the named credential.
    [
      {env_name(base, "GH_TOKEN"), token},
      {env_name(base, "GITHUB_TOKEN"), nil}
      | Enum.reject(base, fn {key, _value} -> key in ["GH_TOKEN", "GITHUB_TOKEN"] end)
    ]
  end

  defp bot_token_env(_opts, _unavailable), do: []

  # `System.cmd` accepts env names as strings or charlists; normalise so the
  # rejection above and the key below agree.
  defp env_name(base, name) do
    if Enum.any?(base, fn {key, _value} -> is_list(key) end), do: String.to_charlist(name), else: name
  end

  defp installed_host_wrapper(bin_dir) do
    bin_dir = bin_dir || AgentGitHubGuard.host_bin_dir()
    path = Path.join(bin_dir, "gh")

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 -> path
      _not_installed -> nil
    end
  rescue
    _unavailable -> nil
  end
end
