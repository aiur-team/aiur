defmodule Aiur.RepoBase do
  @moduledoc """
  Maintains a warm base checkout of the target repo's `main` at
  `~/.aiur/repo/<owner>/<name>` so per-issue workspaces can spin off from it
  (copy or `git worktree`) instead of cold-cloning and recompiling on every
  dispatch.

  A single GenServer serializes refreshes so parallel dispatches never read a
  half-updated base. The base build itself is a dev-authored `base_setup` hook
  (the build command is repo/toolchain-specific), run in the base dir on a
  fresh clone and after every `main` advance. `_build`/deps are gitignored, so
  `reset --hard origin/main` updates tracked source but leaves build artifacts
  in place — the refresh is itself incremental.

  The base path is exposed to workspace hooks as `THIS_REPO_BASE`; the
  dev-authored `after_create` hook copies or `git worktree`s from it.
  """
  use GenServer
  require Logger

  alias Aiur.AgentEnvironment
  alias Aiur.Config

  @built_marker ".aiur-base-built"
  @default_branch "main"
  @call_timeout 600_000

  # ---- Public API ----

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensures the warm base for `repo_url` exists and is at latest `origin/main`,
  running `base_setup` when `main` advanced or the base was never built.
  Returns `{:ok, base_path}` or `{:error, reason}`. Serialized via the
  GenServer call queue.
  """
  @spec ensure_fresh(String.t()) :: {:ok, Path.t()} | {:error, term()}
  def ensure_fresh(repo_url) when is_binary(repo_url) do
    GenServer.call(__MODULE__, {:ensure_fresh, repo_url}, @call_timeout)
  end

  @doc """
  Absolute path of the warm base for `repo_url`, under the configured base root
  (`:aiur, :repo_base_root`, default `~/.aiur/repo`).
  """
  @spec base_path(String.t()) :: Path.t()
  def base_path(repo_url) when is_binary(repo_url) do
    Path.join(base_root(), slug(repo_url))
  end

  # ---- Core (no GenServer; exercised directly in tests) ----

  @doc """
  Ensures `base_path` is a clone of `repo_url` checked out at latest
  `origin/main`, running `base_setup` (when non-nil) on first build and after
  every `main` advance. Returns `{:ok, base_path}` or `{:error, reason}`.
  """
  @spec refresh(Path.t(), String.t(), String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def refresh(base_path, repo_url, base_setup) do
    with :ok <- ensure_clone(base_path, repo_url),
         {:ok, changed?} <- fetch_and_reset(base_path) do
      maybe_build(base_path, base_setup, changed? or not built?(base_path))
    end
  end

  defp maybe_build(base_path, _base_setup, false), do: {:ok, base_path}

  defp maybe_build(base_path, base_setup, true) do
    case run_base_setup(base_path, base_setup) do
      :ok ->
        mark_built(base_path)
        {:ok, base_path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- GenServer ----

  @impl true
  def init(_opts) do
    schedule_poll()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:ensure_fresh, repo_url}, _from, state) do
    {:reply, refresh(base_path(repo_url), repo_url, base_setup_command()), state}
  end

  @impl true
  def handle_info(:poll, state) do
    poll_warm_base()
    schedule_poll()
    {:noreply, state}
  end

  # Proactively refresh the warm base on a cadence so the first dispatch doesn't
  # pay the refresh latency. Runs inside the GenServer (serialized with
  # handle_call), so it calls refresh/3 directly rather than ensure_fresh/1
  # (which would deadlock on a self-call). Best-effort; a failure is dropped and
  # retried on the next tick. No-op unless a github repo + base_setup are
  # configured.
  defp poll_warm_base do
    with {:ok, settings} <- Config.settings(),
         command when is_binary(command) and command != "" <- settings.hooks.base_setup,
         repo when is_binary(repo) and repo != "" <- Aiur.GitHub.Config.repo() do
      url = "https://github.com/#{repo}.git"
      _ = refresh(base_path(url), url, command)
      :ok
    else
      _ -> :ok
    end
  end

  defp schedule_poll do
    case poll_interval_ms() do
      ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :poll, ms)
      _ -> :ok
    end
  end

  defp poll_interval_ms do
    case Config.settings() do
      {:ok, settings} -> max(settings.repo_base_poll_seconds || 0, 0) * 1000
      _ -> 0
    end
  end

  # ---- internals ----

  defp ensure_clone(base_path, repo_url) do
    if File.dir?(Path.join(base_path, ".git")) do
      :ok
    else
      File.rm_rf!(base_path)
      File.mkdir_p!(Path.dirname(base_path))

      case git(["clone", "--branch", @default_branch, repo_url, base_path], nil) do
        {_out, 0} -> :ok
        {out, status} -> {:error, {:repo_base_clone_failed, status, out}}
      end
    end
  end

  defp fetch_and_reset(base_path) do
    with {_fetch, 0} <- git(["fetch", "origin", @default_branch, "--quiet"], base_path),
         {local, 0} <- git(["rev-parse", "HEAD"], base_path),
         {remote, 0} <- git(["rev-parse", "origin/#{@default_branch}"], base_path) do
      reset_if_changed(base_path, String.trim(local) == String.trim(remote))
    else
      {out, status} -> {:error, {:repo_base_fetch_failed, status, out}}
    end
  end

  defp reset_if_changed(_base_path, true), do: {:ok, false}

  defp reset_if_changed(base_path, false) do
    case git(["reset", "--hard", "origin/#{@default_branch}"], base_path) do
      {_out, 0} -> {:ok, true}
      {out, status} -> {:error, {:repo_base_reset_failed, status, out}}
    end
  end

  defp run_base_setup(_base_path, nil), do: :ok
  defp run_base_setup(_base_path, ""), do: :ok

  defp run_base_setup(base_path, command) do
    # Same execution shape as workspace hooks: scrub the operator's Erlang
    # distribution env at the shell level, then run in the base dir. The
    # dev-authored hook sets its own HEX_HOME/MIX_HOME (as the after_create
    # hook does), so the base owns persistent caches workspaces can copy.
    scrubbed = AgentEnvironment.scrub_shell_command(command)

    {out, status} =
      System.cmd("sh", ["-lc", scrubbed], cd: base_path, stderr_to_stdout: true)

    case status do
      0 -> :ok
      _ -> {:error, {:base_setup_failed, status, out}}
    end
  end

  defp git(args, nil), do: System.cmd("git", args, stderr_to_stdout: true)
  defp git(args, cwd), do: System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)

  defp built?(base_path), do: File.exists?(Path.join(base_path, @built_marker))
  defp mark_built(base_path), do: File.write!(Path.join(base_path, @built_marker), "")

  defp base_setup_command do
    case Config.settings() do
      {:ok, settings} -> settings.hooks.base_setup
      _ -> nil
    end
  end

  defp base_root do
    Application.get_env(:aiur, :repo_base_root) || Path.expand("~/.aiur/repo")
  end

  # Reduce a repo URL or local path to a stable `<owner>/<name>`-style slug for
  # the base directory. Handles https/ssh URLs and bare local paths.
  defp slug(repo_url) do
    repo_url
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
    |> String.split(~r{[/:]})
    |> Enum.reject(&(&1 in ["", "https", "http", "ssh", "git", "github.com"]))
    |> Enum.take(-2)
    |> Enum.join("/")
  end
end
