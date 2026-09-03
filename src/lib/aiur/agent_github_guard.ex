defmodule Aiur.AgentGitHubGuard do
  @moduledoc """
  Installs the fleet guards that wrap agent-launched `gh` and `git` commands.

  The wrappers are embedded at compile time so local and SSH workers receive
  the same behavior from an OTP release without depending on the source
  checkout.
  """

  require Logger

  alias Aiur.AgentCommandInstaller
  alias Aiur.GitHub.Budget

  @gh_script_path Path.expand("../../priv/github_quota_guard.sh", __DIR__)
  @git_script_path Path.expand("../../priv/github_push_guard.sh", __DIR__)
  @broker_path Path.expand("../../priv/github_budget.py", __DIR__)
  @external_resource @gh_script_path
  @external_resource @git_script_path
  @external_resource @broker_path
  @gh_script File.read!(@gh_script_path)
  @git_script File.read!(@git_script_path)
  # The budget broker is embedded at compile time and re-installed into every
  # workspace on each local dispatch (`Provisioner.maybe_install_agent_support`
  # runs `install/1` on every worker attempt). A workspace therefore runs the
  # broker of the daemon's currently-compiled release — never the stale
  # `src/priv/github_budget.py` from the workspace's own checkout — which is
  # what keeps the shared ledger free of rows a newer broker cannot read (#2307).
  #
  # Staleness is bounded by the daemon's own release, not by dispatch: because
  # `@broker` is a compile-time embed, a workspace built under an older release
  # keeps the older broker until (a) a new release is built and installed and
  # (b) the workspace next dispatches. Until then it is exactly the stale
  # population #2307 describes, and the guard's marker plus the daemon's alert
  # are what surface it; `maybe_log_stale_broker` records the replacement when
  # it finally happens.
  #
  # Chosen over resolving the broker from the daemon's installed `priv/`
  # directly: an agent workspace must stay self-contained on a remote worker,
  # and a workspace-local copy that is re-installed on every dispatch is just as
  # fresh once the release moves. The accepted tension is that the agent that
  # *writes* a broker change exercises it through `Aiur.GitHub.BudgetTest`
  # (which resolves the broker from the source `priv/`), not through the
  # daemon-run broker in its own workspace — the same tension the issue called
  # out for either choice.
  @broker File.read!(@broker_path)
  @scripts [{"gh", @gh_script}, {"git", @git_script}, {"aiur-github-budget", @broker}]
  @relative_bin_dir ".aiur-runtime/bin"
  @relative_gh_config_dir ".aiur-runtime/gh"
  @broker_relative_path ".aiur-runtime/bin/aiur-github-budget"
  @legacy_host_guard_path Path.join(System.user_home!(), ".aiur/github-budget/bin/gh")
  # #2356: the credential file the `gh` guard reads. It lives beside the shared
  # budget database — the same host-wide directory every agent on a host
  # already shares — so the wrapper can authenticate a governed call without a
  # raw token ever appearing in an agent's environment.
  @agent_token_filename "agent-token"

  @spec bin_dir(Path.t()) :: Path.t()
  def bin_dir(workspace), do: AgentCommandInstaller.bin_dir(workspace, @relative_bin_dir)

  @spec budget_broker_path(Path.t()) :: Path.t()
  def budget_broker_path(workspace), do: Path.join(workspace, @broker_relative_path)

  @doc """
  The path to the credential file the `gh` guard reads for governed agent
  calls. The file lives in the shared budget root so the wrapper on every
  workspace resolves the same host credential without a token in any
  environment.
  """
  @spec agent_token_path() :: Path.t()
  def agent_token_path, do: Path.join(Budget.state_dir(), @agent_token_filename)

  @doc """
  Writes the bot PAT to the guard's credential file.

  ## Contract

  The credential comes from `:token`, falling back to the daemon's own
  `GITHUB_TOKEN`/`GH_TOKEN`. `nil` and `""` mean "not supplied" and consult that
  fallback, exactly as an absent `:token` key does.

  Exactly one input removes the file: the explicit `token: :none` sentinel,
  which asserts there is deliberately no credential and never consults the
  environment. It returns `:no_credential` after deleting.

  **Failing to resolve a credential does not delete anything.** It logs a
  warning, leaves any existing file untouched, and returns `:no_credential`.
  This is deliberate and is the fix for #2478: #2356 scrubs
  `GITHUB_TOKEN`/`GH_TOKEN` from every agent environment, so "this process
  resolved nothing" is the *normal* state for anything an agent runs — including
  `mix test`, which starts the application and so reaches the boot call in
  `Aiur.start/2`. Treating that as "no credential exists" deleted the live
  credential file the whole local fleet authenticates with, once per suite run,
  silently. A process that cannot see a token has learned nothing about whether
  one exists, and must not act destructively on that absence.

  Staleness is still handled where it is genuinely knowable: a daemon that holds
  a token overwrites the file on every boot, and `remote_install_script/2`
  clears a stale token on a host it installs onto over SSH.

  Agents used to inherit the raw `GITHUB_TOKEN`/`GH_TOKEN` from the daemon
  environment; anything that spoke HTTP directly — curl, Req, a Python script,
  a Node fetch — was authenticated, unmetered and untraced (#2356). The daemon
  now keeps the credential off the agent environment entirely and writes it to
  this file instead; `Aiur.AgentEnvironment` scrubs the env vars and exports
  `AIUR_GITHUB_CREDENTIAL_FILE` so the `gh` guard can inject the credential only for
  the duration of a governed call.

  The credential written is the daemon's own inherited `GITHUB_TOKEN`/`GH_TOKEN`
  (the bot PAT agents legitimately publish as) — deliberately NOT
  `Aiur.GitHub.Config.token/0`, which under App auth resolves the daemon's
  installation token. The App installation token is the branch-protection
  bypass actor and a different budget pool; it must never reach agents.

  This is a policy boundary, not a capability boundary: agents run as the same
  OS user as the daemon, so an agent that knows the path can read the file —
  exactly as it could already read the shared budget database and the operator
  keyring. What the file removes is the raw token from the *environment* of
  every agent process, where any dependency's build script or a bare `curl`
  picks it up without even looking.
  """
  @spec ensure_agent_token_file(keyword()) :: :ok | :no_credential | {:error, term()}
  def ensure_agent_token_file(opts \\ []) do
    path = Keyword.get(opts, :path, agent_token_path())

    case resolve_credential(opts) do
      token when is_binary(token) and token != "" ->
        with :ok <- ensure_token_parent(path, opts) do
          write_agent_token_file(path, token)
        end

      _no_credential ->
        # Deleting requires the caller to *declare* there is no credential
        # (`token: :none`). "This process could not resolve one" is not the same
        # claim, and on the daemon's own host it is usually false: #2356 scrubs
        # `GITHUB_TOKEN`/`GH_TOKEN` from every agent environment, so any boot
        # from a scrubbed shell — notably `mix test`, which starts the
        # application and reaches this call — resolved no credential and deleted
        # the live shared file the whole local fleet authenticates with. That
        # made the credential vanish seconds after each restore, with no restart
        # and no rebuild (#2478).
        #
        # The staleness property #2356 wanted is preserved where it is real: a
        # daemon that holds a token overwrites the file on every boot, an
        # explicit `:none` still cleans it, and the remote install script still
        # clears a stale token on the remote host it installs onto.
        if Keyword.get(opts, :token) == :none do
          delete_agent_token_file(path)
        else
          Logger.warning("no GitHub credential resolved; leaving the agent credential file untouched path=#{path}")

          :no_credential
        end
    end
  end

  # Resolves the credential to install, from `:token` or the daemon's own
  # environment.
  #
  # `Keyword.fetch/2` used to gate the environment fallback, so a caller that
  # passed `token: nil` got `{:ok, nil}` and skipped the fallback entirely —
  # only an *absent* key ever consulted the environment. A daemon that provably
  # held `GITHUB_TOKEN` therefore still resolved "no credential" and took the
  # destructive branch (#2478). `nil` and `""` mean "not supplied", the same as
  # an absent key; a caller that means "there is deliberately no credential"
  # says so with the explicit `:none` sentinel, which never consults the
  # environment.
  #
  # `:env_reader` exists so the fallback can be exercised deterministically.
  # Several test modules already mutate `GITHUB_TOKEN` globally under
  # `async: true`, and the regression that pins this branch must not be
  # decided by which of them happens to be running. It defaults to the real
  # process environment.
  defp resolve_credential(opts) do
    case Keyword.get(opts, :token) do
      :none ->
        nil

      token when is_binary(token) and token != "" ->
        token

      _absent_or_blank ->
        read_env = Keyword.get(opts, :env_reader, &System.get_env/1)
        read_env.("GITHUB_TOKEN") || read_env.("GH_TOKEN")
    end
  end

  defp ensure_token_parent(path, opts) do
    if path == agent_token_path() do
      Budget.ensure_state_dir(Keyword.drop(opts, [:path, :token, :env_reader, :remote_host]))
    else
      case File.mkdir_p(Path.dirname(path)) do
        :ok -> :ok
        {:error, reason} -> {:error, {:agent_token_dir_unavailable, Path.dirname(path), reason}}
      end
    end
  end

  defp write_agent_token_file(path, token) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

    with {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]),
         :ok <- IO.binwrite(file, token),
         :ok <- IO.binwrite(file, "\n"),
         :ok <- File.close(file),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, {:agent_token_file_write_failed, path, reason}}
    end
  end

  defp delete_agent_token_file(path) do
    case File.rm(path) do
      :ok -> :no_credential
      {:error, :enoent} -> :no_credential
      {:error, reason} -> {:error, {:agent_token_file_unavailable, path, reason}}
    end
  end

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
    maybe_log_stale_broker(workspace)

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

  # A workspace provisioned under an older release keeps its old broker until
  # its next dispatch replaces it. That replacement is the fix for #2307, so
  # make it observable: a log line records when a stale broker was just
  # overwritten with the current release's broker, which is also the evidence
  # that agent-side 304 reconciliation has been restored for this workspace.
  defp maybe_log_stale_broker(workspace) do
    installed = Path.join(bin_dir(workspace), "aiur-github-budget")

    case File.read(installed) do
      {:ok, existing} when existing != @broker ->
        Logger.warning("refreshing stale agent budget broker workspace=#{workspace}")

      _current_or_missing ->
        :ok
    end
  end

  @spec remote_install_script(Path.t(), keyword()) :: String.t()
  def remote_install_script(workspace, opts \\ []) when is_binary(workspace) do
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
    token_file = remote_agent_token_script(opts)

    scripts <>
      "\nif [ -L #{config_dir} ] || { [ -e #{config_dir} ] && [ ! -d #{config_dir} ]; }; then\n" <>
      "  echo 'unsafe agent gh config dir' >&2\n  exit 73\nfi\n" <>
      "mkdir -p #{config_dir} || { echo 'agent gh config dir is unavailable' >&2; exit 73; }\n" <>
      token_file
  end

  # Remote workers get the same #2356 credential file the local `gh` guard
  # reads (`~/.aiur/github-budget/agent-token`), written from the daemon's own
  # inherited bot PAT. The token travels inside the install script the daemon
  # already ships over SSH — the same trust boundary as the guard payload
  # itself — and is deleted when no credential is available so a stale install
  # cannot leave a dead token authenticating the next agent.
  #
  # That deletion is scoped to a genuinely remote install (#2478). `$HOME` in
  # this script is somebody else's home only when the script really runs over
  # SSH; the string is generated in-process and is executed against the
  # *operator's own* `$HOME` by anything that runs it locally — the installer
  # tests do exactly that, four times per suite run. Because #2356 scrubs
  # `GITHUB_TOKEN`/`GH_TOKEN` from every agent environment, an agent running the
  # suite resolves no credential, so each run emitted
  # `rm -f "$HOME/.aiur/github-budget/agent-token"` and destroyed the single
  # shared credential every local agent authenticates with — while the tests
  # stayed green.
  #
  # Scoping beats namespacing here: the path must stay exactly where the remote
  # `gh` guard looks for it, so it cannot be made per-worker without changing
  # the lookup on both sides. The cleanup is meaningful only for an install that
  # really lands on another host, and only the remote provisioning path knows
  # that. Making it opt-in via `:remote_host` leaves the destructive branch
  # unreachable from every caller that generates or executes this script
  # locally, while preserving the stale-install property where it applies.
  defp remote_agent_token_script(opts) do
    case resolve_credential(opts) do
      token when is_binary(token) and token != "" ->
        token = Aiur.Shell.escape(token)

        [
          "mkdir -p \"$HOME/.aiur/github-budget\"",
          "printf '%s\\n' #{token} > \"$HOME/.aiur/github-budget/agent-token\"",
          "chmod 600 \"$HOME/.aiur/github-budget/agent-token\""
        ]
        |> Enum.join("\n")

      _no_credential ->
        if remote_install?(opts) do
          "rm -f \"$HOME/.aiur/github-budget/agent-token\" 2>/dev/null || true\n"
        else
          "# no GitHub credential available; leaving the host credential file untouched\n"
        end
    end
  end

  defp remote_install?(opts) do
    case Keyword.get(opts, :remote_host) do
      host when is_binary(host) and host != "" -> true
      _local_or_unknown -> false
    end
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
