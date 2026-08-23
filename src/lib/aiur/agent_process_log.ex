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
  # The argv allowlist: only this many leading tokens of a command line are ever
  # examined. Each token is then kept verbatim only if it matches a known-safe
  # shape (`safe_token?/1`); credentials live anywhere in argv, so the per-token
  # allowlist — not a denylist of "known credential shapes" — is the real
  # security boundary, and this cap bounds the recorded row size.
  @max_argv_tokens 8

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
      processes_fun: Keyword.get(opts, :processes_fun, &ps_snapshot/0),
      cwd_fun: Keyword.get(opts, :cwd_fun, &proc_cwd/1),
      path: Keyword.get(opts, :path, default_path()),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      processes: Keyword.get(opts, :processes, %{})
    }
  end

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)

  defp sweep(state) do
    now = state.clock.()
    {tree, tickets} = observe_tree(state)

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

    {starts, exits} = diff_processes(state.processes, seen)

    Enum.each(starts, fn {_key, entry} -> append(state.path, start_row(now, entry)) end)
    Enum.each(exits, fn {_key, entry} -> append(state.path, exit_row(now, entry)) end)

    %{state | processes: seen}
  end

  # Returns `{tree, tickets}` where `tree` is `%{pid => %{root_pid, ppid, comm,
  # cmdline, cwd, start_time}}` for every process under every registered agent
  # root and `tickets` maps the root pid to its reaper `ticket` meta.
  defp observe_tree(state) do
    roots = state.roots_fun.()
    tickets = Map.new(roots, fn {root_pid, ticket} -> {root_pid, ticket} end)
    all = state.processes_fun.()
    index = children_index(all)

    {tree, _claimed} =
      Enum.reduce(roots, {%{}, %{}}, fn {root_pid, _ticket}, {tree, claimed} ->
        walk_root(root_pid, index, all, state.cwd_fun, tree, claimed)
      end)

    {tree, tickets}
  end

  # `%{ppid => [pid, ...]}` so each sweep walks the tree with no per-process
  # subprocess spawns.
  defp children_index(all) do
    Enum.reduce(all, %{}, fn {pid, info}, acc ->
      ppid = Map.get(info, :ppid, 0)
      Map.update(acc, ppid, [pid], &[pid | &1])
    end)
  end

  defp walk_root(root_pid, index, all, cwd_fun, tree, claimed) do
    {tree, claimed} =
      put_process(tree, claimed, root_pid, root_pid, 0, Map.get(all, root_pid), cwd_fun)

    walk_queue([root_pid], MapSet.new([root_pid]), root_pid, index, all, cwd_fun, tree, claimed)
  end

  defp walk_queue([], _seen, _root, _index, _all, _cwd_fun, tree, claimed), do: {tree, claimed}

  defp walk_queue([pid | rest], seen, root, index, all, cwd_fun, tree, claimed) do
    {tree, claimed, seen, children} =
      Enum.reduce(Map.get(index, pid, []), {tree, claimed, seen, []}, fn child_pid, acc ->
        if MapSet.member?(elem(acc, 2), child_pid) do
          acc
        else
          {tree, claimed} =
            put_process(elem(acc, 0), elem(acc, 1), child_pid, root, pid, Map.get(all, child_pid), cwd_fun)

          {tree, claimed, MapSet.put(elem(acc, 2), child_pid), [child_pid | elem(acc, 3)]}
        end
      end)

    walk_queue(rest ++ children, seen, root, index, all, cwd_fun, tree, claimed)
  end

  # Adds `pid` to the tree under `root_pid` (the registered agent root of the
  # walk) with `ppid` from the walk. `claimed` (`%{pid => root_pid}`) and
  # `Map.put_new` keep the first root that claims a pid, so a child that ends
  # up reachable from two registered roots (nested roots, re-parenting) is
  # attributed once.
  defp put_process(tree, claimed, pid, root_pid, ppid, info, cwd_fun) do
    case info do
      %{comm: comm} ->
        claimed = Map.put_new(claimed, pid, root_pid)

        tree =
          Map.put_new(tree, pid, %{
            root_pid: root_pid,
            ppid: ppid,
            pid: pid,
            comm: comm,
            cmdline: Map.get(info, :cmdline, ""),
            start_time: Map.get(info, :start_time),
            cwd: cwd_fun.(pid)
          })

        {tree, claimed}

      nil ->
        {tree, claimed}
    end
  end

  defp diff_processes(previous, seen) do
    starts =
      seen
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(previous, &1))
      |> Map.new(&{&1, seen[&1]})

    exits =
      previous
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(seen, &1))
      |> Map.new(&{&1, previous[&1]})

    {starts, exits}
  end

  defp start_row(now, entry) do
    {argv, argv_sha} = argv_record(entry.cmdline)

    join([
      unix(now),
      "start",
      entry.root_pid,
      entry.ticket || "",
      entry.pid,
      entry.ppid,
      entry.comm,
      argv,
      argv_sha,
      entry.cwd,
      ""
    ])
  end

  defp exit_row(now, entry) do
    duration =
      case Map.get(entry, :first_seen) do
        %DateTime{} = first -> max(DateTime.diff(now, first, :second), 0)
        _unknown -> ""
      end

    join([
      unix(now),
      "exit",
      entry.root_pid,
      entry.ticket || "",
      entry.pid,
      entry.ppid,
      entry.comm,
      "",
      "",
      "",
      duration
    ])
  end

  defp unix(now), do: Integer.to_string(DateTime.to_unix(now))

  # Every cell is escaped so an arbitrary byte in a recorded field (a literal
  # newline in cwd, a tab, a backslash) cannot break the line structure or
  # forge a fake row. argv itself is already whitespace-normalized by
  # `argv_record`, so the escaping is what protects the verbatim fields and is
  # defense-in-depth for every other cell. Backslash first, then the control
  # characters, so the encoding is round-trippable and a literal backslash is
  # never confused with an escape.
  defp join(fields) do
    Enum.map_join(fields, "\t", fn field ->
      field
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\t", "\\t")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
    end)
  end

  # The argv allowlist. Each of the first `@max_argv_tokens` tokens is recorded
  # verbatim only if it matches a known-safe shape; every other token — a
  # credential in any encoding, a URL, a `KEY=value`, or a bare positional
  # word — is replaced by `<redacted>`. When the command line is longer than
  # the token cap, the tail is never recorded at all. Whenever the recorded
  # argv is lossy (a redacted token, or a dropped tail), the whole line is
  # reduced to a SHA-256 fingerprint so identical invocations can still be
  # correlated without reproducing their content.
  defp argv_record(cmdline) when is_binary(cmdline) and cmdline != "" do
    tokens = String.split(cmdline, ~r/\s+/, trim: true)
    {kept, dropped} = Enum.split(tokens, @max_argv_tokens)

    {shown, redacted?} =
      Enum.map_reduce(kept, false, fn token, redacted? ->
        if safe_token?(token) do
          {token, redacted?}
        else
          {"<redacted>", true}
        end
      end)

    shown = Enum.join(shown, " ")

    case {dropped, redacted?} do
      {[], false} -> {shown, ""}
      {[], true} -> {shown, argv_fingerprint(cmdline)}
      {_tail, _redacted} -> {shown <> " <...>", argv_fingerprint(cmdline)}
    end
  end

  defp argv_record(_other), do: {"", ""}

  defp argv_fingerprint(cmdline) do
    :crypto.hash(:sha256, cmdline) |> Base.encode16(case: :lower)
  end

  # A token is recorded only when its shape cannot carry a credential. Two
  # shapes qualify: a bare dash flag (`-S`, `--verbose` — never a `--key=value`
  # form) and a filesystem path (`/ws/…`, `./mix.exs`, `../deps/…`). Everything
  # else — including any bare word, because a bare positional secret is
  # indistinguishable from a benign word — is treated as potentially sensitive
  # and redacted. The length cap keeps a pathological flag or path from
  # bloating a row; paths past it are simply not reproduced.
  @safe_flag ~r/\A--?[A-Za-z0-9][A-Za-z0-9_-]*\z/
  @safe_path ~r{\A(?:/|\./|\.\./)[A-Za-z0-9_./~-]+\z}
  @safe_token_max_bytes 1024

  defp safe_token?(token) do
    byte_size(token) <= @safe_token_max_bytes and
      (Regex.match?(@safe_flag, token) or Regex.match?(@safe_path, token))
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

  defp ps_snapshot do
    case System.find_executable("ps") do
      nil ->
        %{}

      ps ->
        ps_snapshot_with(ps)
    end
  rescue
    _ -> %{}
  end

  defp ps_snapshot_with(ps) do
    case System.cmd(ps, ["-eo", "pid=,ppid=,comm=,args="], stderr_to_stdout: true) do
      {out, 0} -> add_start_times(ps, parse_ps(out))
      _other -> %{}
    end
  end

  # A second `ps` pass reads each pid's start time (`lstart`), so a pid reused
  # inside one sweep window is distinguished from the process that previously
  # held it. When start times are unavailable the log degrades to pid-only
  # identity.
  defp add_start_times(ps, starts) do
    case System.cmd(ps, ["-eo", "pid=,lstart="], stderr_to_stdout: true) do
      {lstarts, 0} -> attach_start_times(starts, parse_lstarts(lstarts))
      _other -> starts
    end
  end

  defp attach_start_times(starts, lstart_by_pid) do
    Map.new(starts, fn {pid, info} ->
      {pid, Map.put(info, :start_time, Map.get(lstart_by_pid, pid))}
    end)
  end

  defp parse_ps(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_ps_line(line) do
        nil -> acc
        {pid, info} -> Map.put(acc, pid, info)
      end
    end)
  end

  defp parse_ps_line(line) do
    with [pid_s, ppid_s, comm | args] <- String.split(String.trim_leading(line), ~r/\s+/, parts: 4),
         {pid, ""} <- Integer.parse(pid_s),
         {ppid, ""} <- Integer.parse(ppid_s),
         true <- pid > 0 do
      {pid, %{pid: pid, ppid: ppid, comm: comm, cmdline: Enum.join(args, " ")}}
    else
      _invalid -> nil
    end
  end

  # `lstart` itself contains spaces (`Sat Aug  9 21:00:00 2026`), so it is
  # parsed as the whole remainder of the line after the pid. The raw string is
  # used as an identity, not a timestamp: a reused pid is distinguished by its
  # start time differing, which needs no timezone or locale parsing.
  defp parse_lstarts(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_lstart_line(line) do
        {pid, lstart} when is_integer(pid) -> Map.put(acc, pid, lstart)
        _invalid -> acc
      end
    end)
  end

  defp parse_lstart_line(line) do
    case String.split(String.trim_leading(line), ~r/\s+/, parts: 2) do
      [pid_s, lstart] -> parse_lstart_pid(pid_s, lstart)
      _malformed -> nil
    end
  end

  defp parse_lstart_pid(pid_s, lstart) do
    case Integer.parse(pid_s) do
      {pid, ""} when pid > 0 -> {pid, lstart}
      _invalid -> nil
    end
  end

  defp proc_cwd(pid) when is_integer(pid) and pid > 0 do
    case File.read_link("/proc/#{pid}/cwd") do
      {:ok, path} -> path
      _ -> ""
    end
  end

  defp proc_cwd(_pid), do: ""

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
