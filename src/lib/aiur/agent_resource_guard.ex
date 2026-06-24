defmodule Aiur.AgentResourceGuard do
  @moduledoc """
  Runtime guard for agent process trees that spawn synthetic CPU load generators.

  The dispatch load gate prevents starting new work on an already-hot host, but
  it cannot constrain a running agent that launches `yes`/`stress` workers to
  reproduce a flake. This guard watches the process roots already registered in
  `Aiur.ProcessReaper` and trims known load-generator descendants above the
  configured per-agent cap.
  """

  use GenServer

  require Logger

  alias Aiur.Claude.RemoteControl

  @default_interval_ms 1_000
  @load_generator_comms ~w(yes stress stress-ng)

  @type proc_info :: %{pid: pos_integer(), comm: String.t(), cmdline: String.t()}
  @type trim_result :: %{root_pid: pos_integer(), cap: non_neg_integer(), killed: [pos_integer()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec enforce_once(keyword()) :: [trim_result()]
  def enforce_once(opts \\ []) do
    cap = Keyword.get_lazy(opts, :cap, &Aiur.Config.synthetic_load_process_cap/0)

    if cap <= 0 do
      []
    else
      entries_fun = Keyword.get(opts, :entries_fun, &Aiur.ProcessReaper.entries/0)

      entries_fun.()
      |> agent_root_pids()
      |> Enum.flat_map(&trim_root(&1, cap, opts))
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

  @doc false
  @spec synthetic_load_generator?(proc_info()) :: boolean()
  def synthetic_load_generator?(%{comm: comm, cmdline: cmdline}) do
    command_name(comm) in @load_generator_comms or command_name(cmdline) in @load_generator_comms
  end

  def synthetic_load_generator?(_info), do: false

  @doc false
  @spec collect_descendants(pos_integer(), keyword()) :: [pos_integer()]
  def collect_descendants(pid, opts \\ []) when is_integer(pid) and pid > 0 do
    children_fun = Keyword.get(opts, :children_fun, &children/1)
    children = children_fun.(pid)
    children ++ Enum.flat_map(children, &collect_descendants(&1, opts))
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      enforce_opts: Keyword.get(opts, :enforce_opts, [])
    }

    schedule_tick(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      enforce_once(state.enforce_opts)
    rescue
      error ->
        Logger.warning("agent_resource_guard failed_open error=#{inspect(error)}")
        []
    after
      schedule_tick(state.interval_ms)
    end

    {:noreply, state}
  end

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp trim_root(root_pid, cap, opts) do
    info_fun = Keyword.get(opts, :process_info_fun, &proc_info/1)
    kill_fun = Keyword.get(opts, :kill_fun, &RemoteControl.graceful_kill/1)

    load_pids =
      root_pid
      |> collect_descendants(opts)
      |> Enum.uniq()
      |> Enum.flat_map(&load_generator_pid(&1, info_fun))
      |> Enum.sort()

    excess = Enum.drop(load_pids, cap)

    case excess do
      [] ->
        []

      pids ->
        Enum.each(pids, kill_fun)

        Logger.warning("agent_resource_guard trimmed_synthetic_load root_pid=#{root_pid} cap=#{cap} killed=#{inspect(pids)}")

        [%{root_pid: root_pid, cap: cap, killed: pids}]
    end
  end

  defp load_generator_pid(pid, info_fun) do
    case info_fun.(pid) do
      nil -> []
      info -> if synthetic_load_generator?(info), do: [pid], else: []
    end
  end

  defp children(pid) when is_integer(pid) and pid > 0 do
    case System.find_executable("pgrep") do
      nil ->
        []

      pgrep ->
        case System.cmd(pgrep, ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
          {out, 0} -> parse_pid_list(out)
          _other -> []
        end
    end
  rescue
    _ -> []
  end

  defp parse_pid_list(out) when is_binary(out) do
    out
    |> String.split()
    |> Enum.flat_map(fn value ->
      case Integer.parse(value) do
        {pid, ""} when pid > 0 -> [pid]
        _ -> []
      end
    end)
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
