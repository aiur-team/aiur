defmodule Aiur.GitHub.Access.Wrapper do
  @moduledoc "Embedded GitHub wrapper artifacts and host installation mechanics."
  require Logger
  alias Aiur.GitHub.Access.WrapperToken
  @broker_root Path.expand("../../../../priv/github_budget", __DIR__)
  @broker_paths Enum.map(~w(00_schema 10_admission 20_report_and_cli), &Path.join(@broker_root, &1 <> ".py"))
  for path <- @broker_paths, do: @external_resource(path)
  @broker_metrics_path Path.expand("../../../../priv/github_budget_metrics.py", __DIR__)
  @external_resource @broker_metrics_path
  @socket_client_path Path.expand("../../../../priv/github_budget_socket.py", __DIR__)
  @external_resource @socket_client_path
  @gh_script Aiur.GitHub.Access.WrapperRecursion.splice(Aiur.GitHub.Access.WrapperSource.aiur(), "gh")
  # The budget broker is embedded at compile time and re-installed into every
  # workspace on each local dispatch (`Provisioner.maybe_install_agent_support`
  # runs `install/1` on every worker attempt). A workspace therefore runs the
  # broker of the daemon's currently-compiled release — never the stale
  # `src/priv/github_budget/` from the workspace's own checkout — which is
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
  # *writes* a broker change exercises it through `Aiur.GitHub.BudgetBrokerSourceTest`
  # (which installs the embedded broker in a test directory), not through the
  # daemon-run broker in its own workspace — the same tension the issue called
  # out for either choice.
  @broker Enum.map_join(@broker_paths, &File.read!/1)
  @broker_metrics File.read!(@broker_metrics_path)
  @socket_client File.read!(@socket_client_path)
  @scripts [
    {"gh", @gh_script},
    {"aiur-github-budget", @broker},
    {"github_budget_metrics.py", @broker_metrics},
    {"aiur-github-budget-socket", @socket_client}
  ]

  @spec scripts() :: [{String.t(), String.t()}]
  def scripts, do: @scripts

  @spec agent_token_path() :: Path.t()
  defdelegate agent_token_path, to: WrapperToken, as: :path

  @spec ensure_agent_token_file(keyword()) :: :ok | :no_credential | {:error, term()}
  defdelegate ensure_agent_token_file(opts \\ []), to: WrapperToken, as: :ensure

  @spec budget_broker_path(Path.t()) :: Path.t()
  def budget_broker_path(workspace), do: Path.join(workspace, ".aiur-runtime/bin/aiur-github-budget")

  @spec host_bin_dir() :: Path.t()
  def host_bin_dir do
    Application.get_env(:aiur, :host_guard_bin_dir) || Path.join(System.user_home!(), ".aiur/bin")
  end

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
  @spec install_host([{String.t(), String.t()}]) :: :ok | {:error, term()}
  def install_host(extra_scripts \\ []) do
    bin = host_bin_dir()

    with :ok <- ensure_directory(Path.dirname(bin)),
         :ok <- ensure_directory(bin),
         :ok <- atomic_install(Path.join(bin, "gh"), @gh_script),
         :ok <- install_extra_scripts(bin, extra_scripts),
         :ok <- atomic_install(Path.join(bin, "aiur-github-budget"), @broker),
         :ok <- atomic_install(Path.join(bin, "github_budget_metrics.py"), @broker_metrics),
         :ok <- retire_legacy_host_guard() do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("host GitHub guard install failed reason=#{inspect(reason)}")
        error
    end
  end

  @doc false
  @spec ensure_directory(Path.t()) :: :ok | {:error, term()}
  def ensure_directory(path) do
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
      path != legacy_host_guard_path() and
      not String.ends_with?(path, "/.aiur-runtime/bin/gh") and
      match?({:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0, File.stat(path))
  end

  # Resolve beside the host wrappers at runtime, never against a build host's
  # compile-time HOME. A test override isolates migration/deletion as well.
  defp legacy_host_guard_path do
    Path.join([Path.dirname(host_bin_dir()), "github-budget", "bin", "gh"])
  end

  defp retire_legacy_host_guard do
    case File.read(legacy_host_guard_path()) do
      {:ok, contents} ->
        if String.contains?(contents, "Fleet guard for agent-launched `gh` calls.") do
          File.rm(legacy_host_guard_path())
        else
          :ok
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:legacy_host_guard_unavailable, legacy_host_guard_path(), reason}}
    end
  end

  defp install_extra_scripts(bin, scripts) do
    Enum.reduce_while(scripts, :ok, fn {name, script}, :ok ->
      case atomic_install(Path.join(bin, name), script) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
