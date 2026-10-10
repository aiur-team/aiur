defmodule Aiur.AgentProcessLog do
  @moduledoc """
  Records agent-workspace subprocess spawns to a durable log.

  The `gh` guard wrapper only sees calls that invoke it. A `git-remote-https`
  clone, a `mix` VM an agent starts to run a test, or a direct `curl`/`Req`
  call from agent code leaves no trace anywhere — the blind spot that turned a
  one-query budget question into a day of live process observation on #2245.
  This observer periodically sweeps the agent process roots registered in
  `Aiur.ProcessReaper`, walks each root's process tree, and appends one row per
  subprocess — command, pid, ppid, cwd, and the ticket whose workspace spawned
  it — plus a duration row when the process exits.

  Combined with the credential fingerprint on every request record
  (`Aiur.GitHub.RequestLog`, the agent wrapper's `agent-requests.tsv`), an
  agent subprocess that touches GitHub is attributable to its ticket: the
  process log names the subprocess and its ticket, and the request records name
  which pool it billed.

  ## Record shape

  Tab-separated, one row per lifecycle event:

  `ts, state, root_pid, ticket, pid, ppid, comm, argv, argv_sha, cwd, duration_s`

  * `state` — `start` (spawned) or `exit` (no longer observed).
  * `root_pid` — the registered agent root process the subprocess descends from.
  * `ticket` — the ticket whose workspace owns the root.
  * `comm` — the executable name, from `ps`.
  * `argv` — an allowlisted view of the command line, never the full argv
    (#2255, #2245): each of the first `@max_argv_tokens` tokens is recorded
    verbatim only when it matches a known-safe shape — a dash flag (`-S`,
    `--verbose`) or a filesystem path (`/ws/…`, `./mix.exs`) — and every other
    token is replaced by `<redacted>`. A denylist over unbounded agent argv
    cannot be made correct: a credential can arrive as a URL userinfo, a
    header value, a `KEY=value`, an encoded blob (padded or not), or a bare
    positional word, and no list of "bad shapes" can anticipate them all. The
    boundary is therefore structural — only tokens positively known to be safe
    are reproduced, and a bare word is never recorded because it cannot be
    verified safe.
  * `argv_sha` — SHA-256 of the full command line whenever the recorded argv is
    lossy (a redacted token, or a tail past the token cap that was never
    written), so two observations of the same command can still be correlated
    without storing its content; blank when every token was recorded verbatim.
  * `duration_s` — set on `exit` rows, blank on `start`.

  ## Scope and the sub-interval gap

  The observer samples the agent process trees every 2 seconds. Any subprocess
  alive at a sample instant is recorded and attributed to the ticket whose
  workspace spawned it. A subprocess that spawns and exits between two samples
  cannot be seen by a poller at all. Calls routed through the `gh` guard are
  covered by `agent-requests.tsv` regardless (its wrapper-pid column joins this
  log's pid), but a wrapper-bypassing call that finishes inside the interval —
  a short-lived `curl`, `Req`, or `git-remote-https` living a few hundred
  milliseconds — leaves this log silent. That is a documented partial for the
  wrapper-bypassing case: budget questions about sub-interval bypasses still
  need live observation, exactly as before this ticket. What this log
  guarantees is that every subprocess that outlives a sample is named and
  ticket-attributed.

  ## Cost and retention

  Each sweep takes one `ps -eo pid=,ppid=,comm=,args=` snapshot plus one
  `ps -eo pid=,lstart=` snapshot (the start time keeps a reused pid from being
  mistaken for the same process), builds a children index in memory, and walks
  the agent roots' trees with no per-process subprocess spawns. The active
  file rotates to `.1` … `.8` at 4 MiB (~36 MiB self-capped), which at the
  capped-argv row size is hours to days of process evidence — comfortably
  outliving the broker `admissions` table's rolling hour. The files live under
  `<repo-state>/github-quota/`, outside `~/.aiur/logs`, so
  `Aiur.Logs.Retention` / `max_log_history_mb` does not govern them; the
  rotation cap is the bound.
  """

  use GenServer

  require Logger

  alias Aiur.AgentProcessLog.{PsSnapshot, Rows}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.RepoBase

  @default_interval_ms 2_000
  # Sized separately from the request logs on purpose: agent builds spawn far
  # more processes than the daemon makes requests, and this log exists to
  # outlive the broker's rolling-hour `admissions` window (#2255). The allowlist
  # argv cap keeps rows ~200 B, so 4 MiB x 8 generations ~ 36 MiB is hours to
  # days of evidence, not the sub-hour retention full argv would produce.
  @max_bytes 4_194_304
  @generations 8

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec sweep_once(keyword()) :: map()
  def sweep_once(opts \\ []) do
    opts
    |> new_state()
    |> sweep()
    |> Map.get(:processes)
  end

  @impl true
  def init(opts) do
    state = new_state(opts)
    schedule_tick(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state =
      try do
        sweep(state)
      rescue
        error ->
          Logger.warning("agent_process_log failed_open error=#{inspect(error)}")
          state
      after
        schedule_tick(state.interval_ms)
      end

    {:noreply, state}
  end

  defp new_state(opts) do
    %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      roots_fun: Keyword.get(opts, :roots_fun, &agent_roots/0),
      processes_fun: Keyword.get(opts, :processes_fun, &PsSnapshot.snapshot/0),
      cwd_fun: Keyword.get(opts, :cwd_fun, &PsSnapshot.proc_cwd/1),
      path: Keyword.get(opts, :path, default_path()),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      processes: Keyword.get(opts, :processes, %{})
    }
  end

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)

  defp sweep(state) do
    now = state.clock.()
    {tree, tickets} = Rows.observe_tree(state)

    seen =
      Map.new(tree, fn {pid, info} ->
        # A pid is only an identity while it is the same process: Linux reuses
        # pids, so a pid that exits and is reallocated inside one sweep window
        # must not inherit the dead process's first_seen (which would fabricate
        # a duration against the wrong command). `start_time` (from
        # `ps -o lstart=`) distinguishes the two; synthetic entries without one
        # key on `{pid, nil}`.
        key = {pid, Map.get(info, :start_time)}

        # Preserve the original first_seen for processes that persist across
        # sweeps, so an exit row reports the process's whole lifetime rather
        # than just the interval since the previous sweep.
        first_seen =
          case Map.get(state.processes, key) do
            %{first_seen: %DateTime{} = previous} -> previous
            _new -> now
          end

        {key,
         info
         |> Map.put(:ticket, Map.get(tickets, info.root_pid))
         |> Map.put(:first_seen, first_seen)
         |> Map.put(:last_seen, now)}
      end)

    {starts, exits} = Rows.diff_processes(state.processes, seen)

    Enum.each(starts, fn {_key, entry} -> append(state.path, Rows.start_row(now, entry)) end)
    Enum.each(exits, fn {_key, entry} -> append(state.path, Rows.exit_row(now, entry)) end)

    %{state | processes: seen}
  end

  defp append(nil, _row), do: :ok

  defp append(path, row) do
    :ok = File.mkdir_p(Path.dirname(path))
    rotate_if_large(path)
    File.write(path, row <> "\n", [:append])
    :ok
  rescue
    _unavailable -> :ok
  end

  defp rotate_if_large(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_bytes -> rotate(path, @generations)
      _other -> :ok
    end
  end

  defp rotate(_path, 0), do: :ok

  defp rotate(path, generation) do
    next = "#{path}.#{generation}"

    if generation == 1 do
      _ = File.rm(next)
      :ok = File.rename(path, next)
    else
      previous = "#{path}.#{generation - 1}"
      if File.exists?(previous), do: File.rename(previous, next)
      rotate(path, generation - 1)
    end

    :ok
  rescue
    _unavailable -> :ok
  end

  # Default sources --------------------------------------------------------

  # The registered agent roots as `[{os_pid, ticket}]`. Pane refs and serve
  # refs are ignored: only an OS process can have a process tree worth walking.
  defp agent_roots do
    Aiur.ProcessReaper.entries()
    |> Enum.flat_map(fn
      {{:os_pid, pid}, :agent, meta} when is_integer(pid) and pid > 0 ->
        ticket =
          case Map.get(meta, :ticket) do
            ticket when is_binary(ticket) and ticket != "" -> ticket
            _unknown -> nil
          end

        [{pid, ticket}]

      _other ->
        []
    end)
    |> Enum.uniq()
  end

  @doc false
  @spec default_path() :: String.t() | nil
  def default_path do
    if Application.get_env(:aiur, :env) == :test do
      # The test env must never write a process log into this checkout's repo
      # state; tests that want one pass `path:` explicitly.
      nil
    else
      resolve_default_path()
    end
  end

  defp resolve_default_path do
    case GitHubConfig.repo() do
      repo when is_binary(repo) and repo != "" ->
        repo
        |> RepoBase.repo_path()
        |> Path.join("github-quota")
        |> Path.join("agent-processes.tsv")

      _unconfigured ->
        nil
    end
  rescue
    _unavailable -> nil
  end
end
