defmodule Aiur.AgentGitHubGuard do
  @moduledoc """
  Installs the fleet guards that wrap agent-launched `gh` and `git` commands.

  The wrappers are embedded at compile time so local and SSH workers receive
  the same behavior from an OTP release without depending on the source
  checkout.
  """

  require Logger

  alias Aiur.AgentCommandInstaller

  @gh_script_path Path.expand("../../priv/github_quota_guard.sh", __DIR__)
  @git_script_path Path.expand("../../priv/github_push_guard.sh", __DIR__)
  @broker_path Path.expand("../../priv/github_budget.py", __DIR__)
  @external_resource @gh_script_path
  @external_resource @git_script_path
  @external_resource @broker_path
  @gh_script File.read!(@gh_script_path)
  @git_script File.read!(@git_script_path)
  @broker File.read!(@broker_path)
  @scripts [{"gh", @gh_script}, {"git", @git_script}, {"aiur-github-budget", @broker}]
  @relative_bin_dir ".aiur-runtime/bin"
  @relative_gh_config_dir ".aiur-runtime/gh"
  @broker_relative_path ".aiur-runtime/bin/aiur-github-budget"
  @legacy_host_guard_path Path.join(System.user_home!(), ".aiur/github-budget/bin/gh")

  @spec bin_dir(Path.t()) :: Path.t()
  def bin_dir(workspace), do: AgentCommandInstaller.bin_dir(workspace, @relative_bin_dir)

  @spec budget_broker_path(Path.t()) :: Path.t()
  def budget_broker_path(workspace), do: Path.join(workspace, @broker_relative_path)

  @doc """
  The agent-private `GH_CONFIG_DIR`.

  SECURITY INVARIANT — this directory holds no credential, and that is the
  point. `gh` resolves auth as `GH_TOKEN`/`GITHUB_TOKEN`, then the host config
  dir (`$GH_CONFIG_DIR`, else `$XDG_CONFIG_HOME/gh`, else `~/.config/gh`) and
  the OS keyring entry that config names. The operator's keyring identity is the
  sole `bypass_actors` entry on the protected branch, so an agent that reaches
  it can approve and merge as the human.

  Pointing agents at an empty workspace-local config dir removes that fallback:
  `env -u GITHUB_TOKEN -u GH_TOKEN gh pr review --approve` — the documented
  bypass — finds no host config and no keyring user, and fails unauthenticated
  instead of succeeding as the operator. Because this is an environment variable
  on the agent process rather than a `PATH` wrapper, it still applies when the
  real `gh` binary is invoked by absolute path.

  The agent's legitimate GitHub access is unaffected: it authenticates with the
  bot PAT in `GITHUB_TOKEN`, which is not a bypass actor. The directory is left
  empty rather than seeded with the bot credential — the token already reaches
  the agent through the environment, so writing a copy to disk would add a
  secret at rest and buy nothing.

  ## What this is not

  This is a **policy boundary, not a capability boundary.** Agents run as the
  same OS user as the Executor, so an agent that goes looking can still read
  `~/.config/gh/hosts.yml`, reach the operator keyring by other means, and read
  the BEAM cookie. What it removes is the documented, one-line `env -u` path and
  every accidental or casually-injected escalation along it — the difference
  between ~32 dispatched agents holding merge authority by default and none of
  them holding it without deliberately breaking out. Real containment needs a
  separate UID or container per agent; do not read this module as providing it.
  """
  @spec gh_config_dir(Path.t()) :: Path.t()
  def gh_config_dir(workspace), do: Path.join(workspace, @relative_gh_config_dir)

  @spec host_bin_dir() :: Path.t()
  def host_bin_dir, do: Path.join(System.user_home!(), ".aiur/bin")

  @spec real_gh() :: Path.t() | nil
  def real_gh do
    System.get_env("PATH", "")
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, "gh"))
    |> Enum.find(&real_gh_path?/1)
  end

  @doc """
  Installs an opt-in wrapper for Executor shells outside the shared budget state.

  The `git` wrapper is installed here too, so any plain-shell caller whose
  `PATH` reaches `~/.aiur/bin` — an operator shell, a CI step, a coordinating
  assistant — is covered by the `git worktree remove` protection (#2094): the
  wrapper refuses removing a worktree that still has a live process rooted in
  it, or one holding uncommitted work. The host wrapper passes every other git
  command through untouched, so the Executor keeps the full git authority it
  holds today (mirroring how the host `gh` wrapper keeps merge authority).
  """
  @spec install_host() :: :ok | {:error, term()}
  def install_host do
    bin = host_bin_dir()

    with :ok <- ensure_directory(Path.join(System.user_home!(), ".aiur")),
         :ok <- ensure_directory(Path.dirname(bin)),
         :ok <- ensure_directory(bin),
         :ok <- atomic_install(Path.join(bin, "gh"), @gh_script),
         :ok <- atomic_install(Path.join(bin, "git"), @git_script),
         :ok <- atomic_install(Path.join(bin, "aiur-github-budget"), @broker),
         :ok <- retire_legacy_host_guard() do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("host GitHub guard install failed reason=#{inspect(reason)}")
        error
    end
  end

  @spec install(Path.t() | nil) :: :ok | {:error, term()}
  def install(workspace) when is_binary(workspace) do
    result =
      Enum.reduce_while(@scripts, :ok, fn {name, script}, :ok ->
        case AgentCommandInstaller.install(workspace, @relative_bin_dir, [name], script, :agent_guard_install_failed) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case with(:ok <- result, do: ensure_gh_config_dir(workspace)) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("agent GitHub guard install failed workspace=#{workspace} reason=#{inspect(reason)}")
        error
    end
  end

  def install(_workspace), do: :ok

  @spec remote_install_script(Path.t()) :: String.t()
  def remote_install_script(workspace) when is_binary(workspace) do
    scripts =
      Enum.map_join(@scripts, "\n", fn {name, script} ->
        AgentCommandInstaller.remote_install_script(workspace, @relative_bin_dir, [name], script)
      end)

    # Remote workers get the same empty agent-private `GH_CONFIG_DIR`; without
    # it an SSH-launched agent still reaches the remote host's `~/.config/gh`.
    # The symlink refusal mirrors `ensure_gh_config_dir/1` — `mkdir -p` alone
    # would succeed against an agent-planted symlink to the operator's config —
    # and the launch fails loudly rather than exporting a variable that points
    # somewhere the agent controls.
    config_dir = Aiur.Shell.escape(gh_config_dir(workspace))

    scripts <>
      "\nif [ -L #{config_dir} ] || { [ -e #{config_dir} ] && [ ! -d #{config_dir} ]; }; then\n" <>
      "  echo 'unsafe agent gh config dir' >&2\n  exit 73\nfi\n" <>
      "mkdir -p #{config_dir} || { echo 'agent gh config dir is unavailable' >&2; exit 73; }\n"
  end

  # SECURITY INVARIANT — the agent owns its workspace, so it can create
  # `ln -s ~/.config/gh <workspace>/.aiur-runtime/gh` and a bare `mkdir_p` would
  # happily succeed against that symlink on the next dispatch, handing the
  # operator keyring straight back. Reuse the same lstat type check the wrapper
  # install path uses and refuse anything that is not a real directory.
  defp ensure_gh_config_dir(workspace) do
    directory = gh_config_dir(workspace)

    case ensure_directory(directory) do
      :ok -> :ok
      {:error, reason} -> {:error, {:agent_gh_config_dir_unavailable, directory, reason}}
    end
  end

  defp ensure_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_agent_support_path, path, type}}
      {:error, :enoent} -> File.mkdir(path)
      {:error, reason} -> {:error, {:agent_support_path_unavailable, path, reason}}
    end
  end

  defp atomic_install(target, script) do
    temporary = target <> ".#{System.unique_integer([:positive])}.tmp"

    with {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]),
         :ok <- IO.binwrite(file, script),
         :ok <- File.close(file),
         :ok <- File.chmod(temporary, 0o755),
         :ok <- File.rename(temporary, target) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, {:agent_guard_install_failed, target, reason}}
    end
  end

  defp real_gh_path?(path) do
    path = Path.expand(path)

    path != Path.join(host_bin_dir(), "gh") and
      path != Path.join(System.user_home!(), ".aiur/github-budget/bin/gh") and
      not String.ends_with?(path, "/.aiur-runtime/bin/gh") and
      match?({:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0, File.stat(path))
  end

  defp retire_legacy_host_guard do
    case File.read(@legacy_host_guard_path) do
      {:ok, contents} ->
        if String.contains?(contents, "Fleet guard for agent-launched `gh` calls.") do
          File.rm(@legacy_host_guard_path)
        else
          :ok
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:legacy_host_guard_unavailable, @legacy_host_guard_path, reason}}
    end
  end
end
