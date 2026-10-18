defmodule Aiur.AgentResourceGuard do
  @moduledoc """
  Runtime guard for agent process trees that spawn synthetic CPU load generators.

  The dispatch load gate prevents starting new work on an already-hot host, but
  it cannot constrain a running agent that launches `yes`/`stress` workers to
  reproduce a flake. This guard watches the process roots already registered in
  `Aiur.ProcessReaper` and trims load-generator descendants above the
  configured per-agent cap. A load generator is a known command name or any
  process `Aiur.AgentResourceGuard.BusyLoop` observes spinning.

  A generator that outlives the agent command that started it usually reparents
  to init and leaves the agent's tree, so it is found by its working directory
  under the workspace root instead and reaped outright: nothing is left to
  stop it, and no cap applies to load nobody is waiting on.

  Only known command names above the cap are killed by default. A process
  flagged by behaviour, and any orphan, is logged and alerted once but left
  running unless `agent.synthetic_load_kill_detected` is set: both rest on
  inference, and a wrong kill costs more than a late one.
  """

  use GenServer

  alias Aiur.AgentResourceGuard.BusyLoop
  alias Aiur.AgentResourceGuard.RunawayGroups
  alias Aiur.ProcessTree
  require Logger

  @default_interval_ms 1_000
  @busy_window_ms 10_000
  @orphan_scan_every_ticks 10
  @alert_topic "system.agent.synthetic_load_cap"
  @load_generator_comms ~w(yes stress stress-ng)

  @type proc_info :: %{pid: pos_integer(), comm: String.t(), cmdline: String.t()}
  @type trim_result :: %{root_pid: pos_integer() | nil, cap: non_neg_integer(), killed: [pos_integer()], reported: [pos_integer()], workspace: Path.t() | nil}
  # Busy-loop sample history, plus the pids already reported without a kill.
  @type tracked :: %{optional(:reported) => MapSet.t(pos_integer()), optional(BusyLoop.key()) => map()}
  @type orphan :: %{pid: pos_integer(), cwd: Path.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec enforce_once(keyword()) :: [trim_result()]
  def enforce_once(opts \\ []), do: opts |> enforce(%{}) |> elem(0)

  @doc false
  # `tracked` is the busy-loop sample history carried between ticks; a spin is
  # only recognised once two ticks have seen the same process.
  @spec enforce(keyword(), tracked()) :: {[trim_result()], tracked()}
  def enforce(opts, tracked) do
    cap = Keyword.get_lazy(opts, :cap, &Aiur.Config.synthetic_load_process_cap/0)

    if cap <= 0 do
      {[], tracked}
    else
      entries_fun = Keyword.get(opts, :entries_fun, &Aiur.ProcessReaper.entries/0)
      orphans_fun = Keyword.get(opts, :orphans_fun, &configured_workspace_orphans/0)
      sample_fun = Keyword.get(opts, :sample_fun, &BusyLoop.sample/1)

      entries = entries_fun.()
      roots = agent_root_pids(entries)
      orphans = Enum.reject(orphans_fun.(), &(&1.pid in roots))
      orphan_pids = MapSet.new(orphans, & &1.pid)
      # One /proc scan per tick, and none without agents: a pgrep per tree node took minutes on a loaded host (#4882).
      opts = tick_children_opts(opts, roots)
      # An orphan can still sit in an agent's tree when a subreaper below the
      # root adopted it; it is reaped as an orphan, not counted toward the cap.
      trees = Enum.map(roots, &{&1, &1 |> collect_descendants(opts) |> Enum.uniq() |> Enum.reject(fn pid -> pid in orphan_pids end)})
      # A root nested in another's tree (the agent under its relay) owns its subtree, so a generator is reported once.
      trees = Enum.map(trees, fn {root, pids} -> {root, pids -- List.flatten(for {inner, sub} <- trees, inner in pids, do: [inner | sub])} end)

      samples =
        (Enum.flat_map(trees, &elem(&1, 1)) ++ Enum.map(orphans, & &1.pid))
        |> Enum.uniq()
        |> Enum.flat_map(&List.wrap(sample_fun.(&1)))

      now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
      {already_reported, tracked} = Map.pop(tracked, :reported, MapSet.new())
      {busy, tracked} = BusyLoop.advance(tracked, samples, now_ms, Keyword.get(opts, :busy_window_ms, @busy_window_ms))
      busy = MapSet.union(busy, all_core_spinners(trees, tracked, Keyword.get_lazy(opts, :cores, &System.schedulers_online/0)))
      opts = opts |> Keyword.put(:busy_pids, busy) |> Keyword.put(:root_tickets, root_tickets(entries)) |> Keyword.put_new_lazy(:kill_detected, &configured_kill_detected/0)

      found = Enum.flat_map(trees, &trim_root(&1, cap, opts)) ++ reap_orphans(orphans, opts)

      # A process left running is still flagged on the next tick; report it once.
      results =
        found
        |> Enum.map(&%{&1 | reported: Enum.reject(&1.reported, fn pid -> pid in already_reported end)})
        |> Enum.reject(&(&1.killed == [] and &1.reported == []))

      Enum.each(results, &report(&1, opts))
      {results, Map.put(tracked, :reported, found |> Enum.flat_map(& &1.reported) |> MapSet.new())}
    end
  end

  @doc false
  # Processes with a cwd under the workspace root that an ended agent command
  # left behind. Selecting by cwd alone would also catch an operator's own
  # shell inside a workspace, so the command must be provably over: either the
  # session leader is gone (agent tool commands run in their own session), or
  # the process was adopted by init or a systemd manager. Another subreaper may
  # adopt it first (the build-gate holder does), which is why the parent alone
  # is not enough.
  @spec workspace_orphans(Path.t(), Path.t()) :: [orphan()]
  def workspace_orphans(workspace_root, proc_dir \\ "/proc") when is_binary(workspace_root) do
    with {:ok, root} <- scan_root(workspace_root),
         {:ok, entries} <- File.ls(proc_dir) do
      procs = for entry <- entries, {pid, ""} <- [Integer.parse(entry)], stat = proc_stat(proc_dir, pid), into: %{}, do: {pid, stat}

      for {pid, %{ppid: ppid, sid: sid}} <- procs,
          ppid == 1 or match?(%{comm: "systemd"}, procs[ppid]) or (sid > 0 and not is_map_key(procs, sid)),
          {:ok, cwd} <- [File.read_link(Path.join([proc_dir, Integer.to_string(pid), "cwd"]))],
          String.starts_with?(cwd, root <> "/") do
        %{pid: pid, cwd: cwd}
      end
    else
      _ -> []
    end
  end

  @doc false
  @spec reap_orphaned_build_gate_holders(keyword()) :: [pos_integer()]
  def reap_orphaned_build_gate_holders(opts \\ []) do
    find_fun = Keyword.get(opts, :orphan_holders_fun, &orphaned_build_gate_holders/0)
    kill_fun = Keyword.get(opts, :orphan_kill_fun, &ProcessTree.reap_process/2)

    for {pid, identity} <- find_fun.() do
      _ = kill_fun.(pid, identity)
      Logger.warning("agent_resource_guard reaped_orphaned_build_gate_holder pid=#{pid}")
      pid
    end
  end

  # Leaked holders lock test temp dirs, never the daemon's gate root, so they are
  # matched by script shape and a vanished lock path, not by location (#4183).
  @doc false
  @spec orphaned_build_gate_holders(Path.t(), (pos_integer() -> {:ok, term()} | :gone | :unknown)) ::
          [{pos_integer(), term()}]
  def orphaned_build_gate_holders(proc_dir \\ "/proc", identity_fun \\ &ProcessTree.process_identity/1) do
    case File.ls(proc_dir) do
      {:ok, entries} ->
        for entry <- entries,
            {pid, ""} <- [Integer.parse(entry)],
            proc_entry = Path.join(proc_dir, entry),
            {:ok, "bash\n"} <- [File.read(Path.join(proc_entry, "comm"))],
            # Identity is captured before argv is read, so a recycled pid fails the reap.
            {:ok, identity} <- [identity_fun.(pid)],
            {:ok, cmdline} <- [File.read(Path.join(proc_entry, "cmdline"))],
            lock_path = holder_lock_path(cmdline),
            is_binary(lock_path),
            not File.exists?(lock_path) do
          {pid, identity}
        end

      _ ->
        []
    end
  end

  @doc false
  @spec agent_root_pids([{term(), term(), term()}]) :: [pos_integer()]
  def agent_root_pids(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(fn
      {{:os_pid, pid}, :agent, _meta} when is_integer(pid) and pid > 0 -> [pid]
      _other -> []
    end)
    |> Enum.uniq()
  end

  defp root_tickets(entries) do
    for {{:os_pid, pid}, :agent, meta} <- entries, ticket = meta[:ticket], is_binary(ticket), into: %{}, do: {pid, ticket}
  end

  @doc false
  @spec synthetic_load_generator?(proc_info()) :: boolean()
  def synthetic_load_generator?(%{comm: comm, cmdline: cmdline}) do
    command_name(comm) in @load_generator_comms or command_name(cmdline) in @load_generator_comms
  end

  def synthetic_load_generator?(_info), do: false

  @doc false
  @spec collect_descendants(pos_integer(), keyword()) :: [pos_integer()]
  def collect_descendants(pid, opts \\ []) when is_integer(pid) and pid > 0 do
    opts = Keyword.put_new_lazy(opts, :children_fun, fn -> proc_children_fun(opts) end)
    children = Keyword.fetch!(opts, :children_fun).(pid)
    children ++ Enum.flat_map(children, &collect_descendants(&1, opts))
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      enforce_opts: Keyword.get(opts, :enforce_opts, []),
      tracked: %{},
      orphans: [],
      ticks_to_scan: 0
    }

    schedule_tick(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    {:reply, :ok, tick(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    {:noreply, tick(state)}
  end

  defp tick(state) do
    state =
      try do
        RunawayGroups.check(state.enforce_opts)
        state = refresh_orphans(state)
        opts = Keyword.put(state.enforce_opts, :orphans_fun, fn -> state.orphans end)
        %{state | tracked: opts |> enforce(state.tracked) |> elem(1)}
      rescue
        error ->
          Logger.warning("agent_resource_guard failed_open error=#{inspect(error)}")
          state
      after
        schedule_tick(state.interval_ms)
      end

    state
  end

  # The orphan scan reads every process on the host (measured ~70-140ms for
  # ~1,100 processes), so it runs every tenth tick; orphans already found are
  # still sampled on every tick.
  defp refresh_orphans(%{ticks_to_scan: 0} = state) do
    orphans_fun = Keyword.get(state.enforce_opts, :orphans_fun, &configured_workspace_orphans/0)
    reap_orphaned_build_gate_holders(state.enforce_opts)
    %{state | orphans: orphans_fun.(), ticks_to_scan: @orphan_scan_every_ticks - 1}
  end

  defp refresh_orphans(state), do: %{state | ticks_to_scan: state.ticks_to_scan - 1}

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  # A tree spinning on every core at once is no flake repro to wait out: flag it
  # on the first sample pair instead of after the busy window.
  defp all_core_spinners(trees, tracked, cores) do
    spinning = for {{pid, _start}, %{since: since}} <- tracked, is_integer(since), into: MapSet.new(), do: pid

    trees
    |> Enum.map(fn {_root, pids} -> Enum.filter(pids, &(&1 in spinning)) end)
    |> Enum.filter(&(length(&1) >= cores))
    |> List.flatten()
    |> MapSet.new()
  end

  defp trim_root({root_pid, descendants}, cap, opts) do
    kill_fun = Keyword.get(opts, :kill_fun, &ProcessTree.graceful_kill/1)
    load_pids = descendants |> Enum.filter(&load_generator?(&1, opts)) |> Enum.sort()
    excess = Enum.drop(load_pids, cap)

    # Without the opt-in only known command names count toward a kill.
    killed = if opts[:kill_detected], do: excess, else: load_pids |> Enum.filter(&named_generator?(&1, opts)) |> Enum.drop(cap)

    case excess do
      [] ->
        []

      _ ->
        Enum.each(killed, kill_fun)
        [%{root_pid: root_pid, cap: cap, killed: killed, reported: excess -- killed, workspace: Keyword.get(opts, :cwd_fun, &proc_cwd/1).(root_pid)}]
    end
  end

  defp reap_orphans(orphans, opts) do
    # SIGKILL without waiting: the adoptive parent may never reap the zombie,
    # and graceful_kill/1 would block the guard for its full grace on each one.
    kill_fun = Keyword.get(opts, :kill_fun, &System.cmd("kill", ["-KILL", Integer.to_string(&1)], stderr_to_stdout: true))

    orphans
    |> Enum.filter(&load_generator?(&1.pid, opts))
    |> Enum.group_by(& &1.cwd, & &1.pid)
    |> Enum.map(fn {cwd, pids} ->
      pids = Enum.sort(pids)
      killed = if opts[:kill_detected], do: pids, else: []
      Enum.each(killed, kill_fun)
      %{root_pid: nil, cap: 0, killed: killed, reported: pids -- killed, workspace: cwd}
    end)
  end

  defp load_generator?(pid, opts), do: MapSet.member?(Keyword.fetch!(opts, :busy_pids), pid) or named_generator?(pid, opts)

  defp named_generator?(pid, opts) do
    info = Keyword.get(opts, :process_info_fun, &proc_info/1).(pid)
    info != nil and synthetic_load_generator?(info)
  end

  defp report(%{workspace: workspace, cap: cap, killed: killed, reported: reported, root_pid: root_pid}, opts) do
    what = if root_pid, do: "exceeded the synthetic load cap of #{cap}", else: "left orphaned synthetic load running"
    info_fun = Keyword.get(opts, :process_info_fun, &proc_info/1)
    cmds = Map.new(killed ++ reported, &{&1, (info_fun.(&1) || %{})[:cmdline]})

    Logger.warning("agent_resource_guard synthetic_load workspace=#{workspace} root_pid=#{inspect(root_pid)} cap=#{cap} killed=#{inspect(killed)} reported=#{inspect(reported)} cmds=#{inspect(cmds)}")

    left = if reported == [], do: "", else: ", left #{length(reported)} running (report-only; set agent.synthetic_load_kill_detected to kill)"

    # The Executor's wake stream carries identifiers only, so a known ticket is
    # raised as that ticket's attention; an orphan has none (#4882).
    ticket = Map.get(Keyword.get(opts, :root_tickets, %{}), root_pid)
    topic = if ticket, do: "ticket.#{ticket}.agent.attention.synthetic-load", else: @alert_topic

    Keyword.get(opts, :alert_fun, &Aiur.Signal.alert/2).(topic,
      issue: ticket,
      message: "Agent workspace #{workspace || "(unknown, agent pid #{root_pid})"} #{what}; killed #{length(killed)} load generator process(es)#{left}",
      reason: "synthetic CPU load generators (by name or busy-loop behaviour) are capped per agent and flagged once orphaned; killed=#{inspect(killed)} reported=#{inspect(reported)}",
      needs_attention: ticket != nil,
      severity: "warning"
    )
  end

  defp configured_kill_detected, do: Aiur.Config.settings!().agent.synthetic_load_kill_detected == true

  # Unit tests must never signal host processes, so the scan shares the
  # reaper's registration switch (false in the test env).
  defp configured_workspace_orphans do
    if Application.get_env(:aiur, :process_reaper_registrations, true),
      do: workspace_orphans(Aiur.Config.workspace_root()),
      else: []
  rescue
    _ -> []
  end

  # procfs reports cwd symlink-resolved, so the root must be canonical too. A
  # mis-resolved "/" or "/home" would make the scan host-wide, and $HOME (or
  # anything above it) would put the operator's own systemd-adopted apps in
  # scope, so refuse those.
  defp scan_root(workspace_root) do
    root = canonical(workspace_root)
    home = canonical(System.user_home() || "/")

    if length(Path.split(root)) >= 3 and not String.starts_with?(home <> "/", root <> "/"), do: {:ok, root}, else: :skip
  end

  defp canonical(path) do
    case Aiur.PathSafety.canonicalize(path) do
      {:ok, path} -> path
      _ -> Path.expand(path)
    end
  end

  defp proc_stat(proc_dir, pid) do
    with {:ok, stat} <- File.read(Path.join([proc_dir, Integer.to_string(pid), "stat"])),
         [_, comm, ppid, sid] <- Regex.run(~r/\((.*)\) \S (\d+) \d+ (\d+) /s, stat) do
      %{comm: comm, ppid: String.to_integer(ppid), sid: String.to_integer(sid)}
    else
      _ -> nil
    end
  end

  defp proc_cwd(pid) do
    case File.read_link(Path.join(["/proc", Integer.to_string(pid), "cwd"])) do
      {:ok, cwd} -> cwd
      _ -> nil
    end
  end

  defp holder_lock_path(cmdline) do
    case String.split(cmdline, <<0>>, trim: true) do
      [bash, "-c", script, "build-gate-holder", lock_path | _rest] ->
        if Path.basename(bash) == "bash" and String.contains?(script, "flock 8") and String.contains?(script, "sleep 0.05"),
          do: lock_path

      _ ->
        nil
    end
  end

  defp tick_children_opts(opts, []), do: opts
  defp tick_children_opts(opts, _roots), do: Keyword.put_new_lazy(opts, :children_fun, fn -> proc_children_fun(opts) end)

  defp proc_children_fun(opts) do
    index = Keyword.get(opts, :children_index_fun, fn -> children_index("/proc") end).()
    &Map.get(index, &1, [])
  end

  defp children_index(proc_dir) do
    case File.ls(proc_dir) do
      {:ok, entries} ->
        Enum.group_by(for(entry <- entries, {pid, ""} <- [Integer.parse(entry)], %{ppid: ppid} <- [proc_stat(proc_dir, pid)], do: {ppid, pid}), &elem(&1, 0), &elem(&1, 1))

      _ ->
        %{}
    end
  end

  defp proc_info(pid) when is_integer(pid) and pid > 0 do
    proc_entry = Path.join("/proc", Integer.to_string(pid))

    case File.read(Path.join(proc_entry, "comm")) do
      {:ok, comm} ->
        cmdline =
          case File.read(Path.join(proc_entry, "cmdline")) do
            {:ok, raw} -> raw |> String.replace(<<0>>, " ") |> String.trim()
            _ -> ""
          end

        %{pid: pid, comm: String.trim(comm), cmdline: cmdline}

      _ ->
        nil
    end
  end

  defp command_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> case do
      nil -> ""
      command -> command |> Path.basename() |> String.trim()
    end
  end

  defp command_name(_value), do: ""
end
