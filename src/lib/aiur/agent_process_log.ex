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

  `ts, state, root_pid, ticket, pid, ppid, comm, cmdline, cwd, duration_s`

  * `state` — `start` (spawned) or `exit` (no longer observed).
  * `root_pid` — the registered agent root process the subprocess descends from.
  * `ticket` — the ticket whose workspace owns the root.
  * `comm` — the executable name, from `ps`.
  * `cmdline` — the full command line with obvious credentials redacted. Tokens
    in argv are the one thing this log must never record verbatim (#2255, #2245).
  * `duration_s` — set on `exit` rows, blank on `start`.

  ## Cost and retention

  Each sweep takes a single `ps -eo pid=,ppid=,comm=,args=` snapshot, builds a
  children index in memory, and walks the agent roots' trees with no per-process
  subprocess spawns. The active file rotates to `.1` then `.2` at 1 MiB, so
  several hours of process evidence survive, the same multi-generation shape as
  the request logs.

  A subprocess that lives shorter than the sweep interval can still be missed;
  the default interval is short (2s) and the wrapper's own pid column catches
  the `gh`/`git` calls regardless.
  """

  use GenServer

  require Logger

  @default_interval_ms 2_000
  @max_bytes 1_048_576
  @generations 2

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec sweep_once(keyword()) :: keyword()
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
        # Preserve the original first_seen for processes that persist across
        # sweeps, so an exit row reports the process's whole lifetime rather
        # than just the interval since the previous sweep.
        first_seen =
          case Map.get(state.processes, pid) do
            %{first_seen: %DateTime{} = previous} -> previous
            _new -> now
          end

        {pid,
         info
         |> Map.put(:ticket, Map.get(tickets, info.root_pid))
         |> Map.put(:first_seen, first_seen)
         |> Map.put(:last_seen, now)}
      end)

    {starts, exits} = diff_processes(state.processes, seen)

    Enum.each(starts, fn {pid, entry} -> append(state.path, start_row(now, pid, entry)) end)
    Enum.each(exits, fn {pid, entry} -> append(state.path, exit_row(now, pid, entry)) end)

    %{state | processes: seen}
  end

  # Returns `{tree, tickets}` where `tree` is `%{pid => %{root_pid, ppid, comm,
  # cmdline, cwd}}` for every process under every registered agent root and
  # `tickets` maps the root pid to its reaper `ticket` meta.
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
            comm: comm,
            cmdline: Map.get(info, :cmdline, ""),
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

  defp start_row(now, pid, entry) do
    join([
      unix(now),
      "start",
      entry.root_pid,
      entry.ticket || "",
      pid,
      entry.ppid,
      entry.comm,
      redact_cmdline(entry.cmdline),
      entry.cwd,
      ""
    ])
  end

  defp exit_row(now, pid, entry) do
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
      pid,
      entry.ppid,
      entry.comm,
      "",
      "",
      duration
    ])
  end

  defp unix(now), do: Integer.to_string(DateTime.to_unix(now))
  defp join(fields), do: Enum.map_join(fields, "\t", &to_string/1)

  # Obvious credential shapes in argv are redacted, never logged. git-remote
  # helpers receive URLs on stdin rather than argv, so the common leak is a
  # curl/Req call carrying `Authorization` or a token query parameter.
  defp redact_cmdline(cmdline) when is_binary(cmdline) do
    cmdline
    |> String.replace(~r/(ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]+/, "\\1_<redacted>")
    |> String.replace(~r/(Authorization:\s*Bearer\s+)\S+/i, "\\1<redacted>")
    |> String.replace(~r/(x-access-token:\s*)\S+/i, "\\1<redacted>")
    |> String.replace(~r/([?&](?:token|access_token|private_key|password)=)[^&\s]+/, "\\1<redacted>")
  end

  defp redact_cmdline(_other), do: ""

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
        case System.cmd(ps, ["-eo", "pid=,ppid=,comm=,args="], stderr_to_stdout: true) do
          {out, 0} -> parse_ps(out)
          _other -> %{}
        end
    end
  rescue
    _ -> %{}
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
    case Aiur.GitHub.Config.repo() do
      repo when is_binary(repo) and repo != "" ->
        repo
        |> Aiur.RepoBase.repo_path()
        |> Path.join("github-quota")
        |> Path.join("agent-processes.tsv")

      _unconfigured ->
        nil
    end
  rescue
    _unavailable -> nil
  end
end
