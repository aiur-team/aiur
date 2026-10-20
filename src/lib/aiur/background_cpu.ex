defmodule Aiur.BackgroundCpu do
  @moduledoc """
  Samples CPU used by external processes niced below the daemon (#3624).

  `/proc/stat` reports one aggregate nice column. This worker scans `/proc/<pid>/stat`
  on its own timer, outside the Orchestrator, and accumulates only CPU ticks
  of processes whose nice is greater than the daemon's own nice and that are
  outside both its process tree and registered fleet-agent process trees.
  Detached agent relays are reparented to systemd, so the relay registry is
  needed to keep their build descendants in the fleet pressure signal.

  Each scan publishes a cumulative reading to ETS: background ticks, the
  `/proc/stat` CPU total at the same moment, the daemon nice, and an epoch.
  `Aiur.SystemCpu.snapshot/0` embeds the latest fresh reading, and
  `Aiur.SystemCpu.headroom/2` divides the two deltas. A new epoch starts when
  the daemon nice changes or a scan fails, so readings from different epochs
  never combine. Unreadable procfs, too many processes, or a stale reading
  publish `:unavailable`, which means no discount.

  The estimate errs low: a process seen for the first time, and a process that
  exits between scans, contribute nothing for that interval.
  """

  use GenServer

  alias Aiur.{Config, ProcessReaper, SystemCpu, SystemPriority}

  @table :aiur_background_cpu
  @default_interval_ms 10_000
  @max_processes 8_192

  @type reading :: %{
          epoch: reference(),
          daemon_nice: integer(),
          ticks: non_neg_integer(),
          cpu_total: non_neg_integer(),
          sampled_at_ms: integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Latest published reading, or `:unavailable` when missing or older than three scan intervals."
  @spec latest(integer()) :: reading() | :unavailable
  def latest(now_ms \\ System.monotonic_time(:millisecond)) do
    case Application.get_env(:aiur, :background_cpu_source_override) do
      fun when is_function(fun, 0) -> fun.()
      _ -> fresh(lookup(), now_ms)
    end
  end

  defp lookup do
    case :ets.lookup(@table, :latest) do
      [{:latest, reading}] -> reading
      _ -> :unavailable
    end
  rescue
    ArgumentError -> :unavailable
  end

  defp fresh(%{sampled_at_ms: at} = reading, now_ms) when now_ms - at <= 3 * @default_interval_ms, do: reading
  defp fresh(_reading, _now_ms), do: :unavailable

  @doc """
  Reads process stats under `proc_root`, keeping niced CPU outside the daemon
  and registered fleet-agent process trees. Returns `:unavailable` when the
  directory cannot be listed or holds more than #{@max_processes} processes.
  """
  @spec scan(Path.t(), integer(), pos_integer(), [pos_integer()]) :: %{optional({String.t(), non_neg_integer()}) => non_neg_integer()} | :unavailable
  def scan(proc_root, daemon_nice, daemon_pid, fleet_roots \\ [])

  def scan(proc_root, daemon_nice, daemon_pid, fleet_roots)
      when is_integer(daemon_nice) and is_integer(daemon_pid) and daemon_pid > 0 and is_list(fleet_roots) do
    with {:ok, entries} <- File.ls(proc_root),
         pids = Enum.filter(entries, &numeric?/1),
         true <- length(pids) <= @max_processes do
      processes = read_processes(proc_root, pids)
      roots = Map.new([daemon_pid | fleet_roots], &{&1, true})

      processes
      |> Enum.reject(fn {pid, process} -> process.nice <= daemon_nice or fleet_process?(pid, processes, roots) end)
      |> Map.new(fn {pid, process} -> {{pid, process.start}, process.ticks} end)
    else
      _ -> :unavailable
    end
  end

  # A process may exit between listing and reading; that is not a failure.
  defp read_processes(proc_root, pids) do
    pids
    |> Enum.map(fn pid ->
      process =
        with {:ok, contents} <- File.read(Path.join([proc_root, pid, "stat"])),
             {:ok, parsed} <- SystemPriority.parse_stat(contents) do
          parsed
        else
          _ -> nil
        end

      {pid, process}
    end)
    |> Enum.reject(fn {_pid, process} -> is_nil(process) end)
    |> Map.new()
  end

  defp fleet_process?(pid, processes, roots),
    do: fleet_process?(String.to_integer(pid), processes, roots, %{})

  defp fleet_process?(pid, processes, roots, seen) do
    cond do
      Map.has_key?(roots, pid) ->
        true

      Map.has_key?(seen, pid) ->
        false

      true ->
        case Map.get(processes, Integer.to_string(pid)) do
          %{parent_pid: parent} when parent > 0 -> fleet_process?(parent, processes, roots, Map.put(seen, pid, true))
          _ -> false
        end
    end
  end

  @doc """
  Folds one scan into the cumulative reading. `previous` is the prior state
  (`nil` on the first scan). Returns the next state; its `:reading` is what
  gets published.
  """
  @spec advance(map() | nil, integer() | :unavailable, map() | :unavailable, non_neg_integer() | :unavailable, integer()) :: map()
  def advance(previous, daemon_nice, processes, cpu_total, now_ms)
      when is_integer(daemon_nice) and is_map(processes) and is_integer(cpu_total) do
    case previous do
      %{reading: %{daemon_nice: ^daemon_nice, ticks: ticks} = reading, processes: seen} ->
        added = Enum.reduce(processes, 0, fn {key, now}, sum -> sum + max(now - Map.get(seen, key, now), 0) end)
        %{processes: processes, reading: %{reading | ticks: ticks + added, cpu_total: cpu_total, sampled_at_ms: now_ms}}

      _ ->
        %{processes: processes, reading: %{epoch: make_ref(), daemon_nice: daemon_nice, ticks: 0, cpu_total: cpu_total, sampled_at_ms: now_ms}}
    end
  end

  def advance(_previous, _daemon_nice, _processes, _cpu_total, _now_ms), do: %{processes: %{}, reading: :unavailable}

  @impl true
  # Tests inject readings through :background_cpu_source_override; a live scan would leak host CPU into them.
  # Idle rather than :ignore, so SupervisionHealth does not count the test app's child as DOWN (#4896).
  def init(opts) do
    if Application.get_env(:aiur, :env) == :test and not Keyword.get(opts, :force?, false), do: {:ok, :idle}, else: start(opts)
  end

  defp start(opts) do
    table = :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    :ets.insert(table, {:latest, :unavailable})
    state = %{previous: nil, interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms), proc_root: Keyword.get(opts, :proc_root, "/proc")}
    send(self(), :scan)
    {:ok, state}
  end

  @impl true
  def handle_info(:scan, state) do
    Process.send_after(self(), :scan, state.interval_ms)

    if enabled?() do
      daemon_nice = SystemPriority.nice()
      daemon_pid = System.pid() |> String.to_integer()
      processes = if is_integer(daemon_nice), do: scan(state.proc_root, daemon_nice, daemon_pid, fleet_roots()), else: :unavailable
      next = advance(state.previous, daemon_nice, processes, cpu_total(), System.monotonic_time(:millisecond))
      :ets.insert(@table, {:latest, next.reading})
      {:noreply, %{state | previous: next}}
    else
      :ets.insert(@table, {:latest, :unavailable})
      {:noreply, %{state | previous: nil}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp cpu_total do
    case SystemCpu.counters() do
      %{total: total} -> total
      _ -> :unavailable
    end
  end

  defp fleet_roots do
    ProcessReaper.entries()
    |> Enum.flat_map(fn
      {{:os_pid, pid}, :agent, _meta} when is_integer(pid) and pid > 0 -> [pid]
      _ -> []
    end)
  catch
    _, _ -> []
  end

  # Mirrors DispatchPolicy.read_cpu/3: explicit-disable configs never scan.
  defp enabled? do
    Enum.any?([&Config.target_load_average/0, &Config.max_load_average/0, &Config.run_queue_threshold/0], fn fun ->
      case fun.() do
        value when is_number(value) and value > 0 -> true
        _ -> false
      end
    end)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp numeric?(<<c, _::binary>> = entry) when c in ?0..?9, do: String.match?(entry, ~r/^\d+$/)
  defp numeric?(_entry), do: false
end
