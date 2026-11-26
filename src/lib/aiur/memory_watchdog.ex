defmodule Aiur.MemoryWatchdog do
  @moduledoc """
  Bounds and watches daemon memory (#7796, #7882).

  `cap_process_heap/0` gives every process started after boot a heap limit, so
  one runaway process is killed (and named by the runtime's error report)
  instead of growing until the kernel OOM killer stops the whole BEAM.

  The watchdog alerts once when the daemon's resident memory (RSS) or
  `:erlang.memory(:total)` passes `monitoring.daemon_memory_alert_fraction` of
  host memory. It first logs the largest processes and ETS tables to the
  daemon log. Each process is probed with a timeout: a process stuck in a huge
  garbage collection does not answer `Process.info/2`, so it is listed as
  unresponsive instead of hanging the watchdog (#7882).
  """

  use GenServer

  require Logger

  alias Aiur.Signal

  @topic "system.daemon.memory_high"
  @interval_ms 10_000
  @default_fraction 0.5
  @top 5
  @probe_timeout_ms 2_000
  # ponytail: a fixed cap; the largest legitimate heap seen is about 750 MiB (#7816).
  @max_process_heap_bytes 4 * 1_073_741_824

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Kills any process spawned after this call whose heap passes the cap; the runtime logs it."
  @spec cap_process_heap(pos_integer()) :: :ok
  def cap_process_heap(bytes \\ @max_process_heap_bytes) do
    words = div(bytes, :erlang.system_info(:wordsize))
    _ = :erlang.system_flag(:max_heap_size, %{size: words, kill: true, error_logger: true})
    :ok
  end

  @doc "One check: alerts on crossing above the line and resolves on falling back below it."
  @spec check(boolean(), keyword()) :: boolean()
  def check(high?, opts \\ []) do
    beam = Keyword.get(opts, :used_fun, fn -> :erlang.memory(:total) end).()
    rss = Keyword.get(opts, :rss_fun, &rss_bytes/0).()
    used = max(beam, rss || 0)
    host = Keyword.get(opts, :host_fun, &host_bytes/0).()
    fraction = Keyword.get(opts, :fraction_fun, &fraction/0).()
    alert = Keyword.get(opts, :alert_fun, &Signal.alert/2)

    case {high?, is_integer(host) and used > fraction * host} do
      {false, true} ->
        snapshot = Keyword.get(opts, :snapshot_fun, &snapshot/0)
        alert.(@topic, high_alert(%{beam: beam, rss: rss, used: used, host: host, fraction: fraction}, snapshot))
        true

      {true, false} ->
        alert.("#{@topic}.resolved", message: "Daemon memory back to #{mib(used)} MiB", needs_attention: false)
        false

      _same ->
        high?
    end
  end

  @impl true
  def init(opts) do
    schedule(opts)
    {:ok, %{opts: opts, high?: false}}
  end

  @impl true
  def handle_info(:check, state) do
    schedule(state.opts)
    {:noreply, %{state | high?: safe_check(state)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A probe or alert failure must not restart this child every tick and take the top supervisor down.
  defp safe_check(state) do
    check(state.high?, state.opts)
  rescue
    error ->
      Logger.warning("memory_watchdog check_failed error=#{Exception.message(error)}")
      state.high?
  catch
    kind, reason ->
      Logger.warning("memory_watchdog check_failed #{kind}=#{inspect(reason)}")
      state.high?
  end

  defp schedule(opts), do: Process.send_after(self(), :check, Keyword.get(opts, :interval_ms, @interval_ms))

  # Logs the crossing before collecting holders, so a failing snapshot still leaves a log line.
  defp high_alert(m, snapshot_fun) do
    message = "Daemon memory #{mib(m.used)} MiB is above #{round(m.fraction * 100)}% of host memory (#{mib(m.host)} MiB)"
    rss = if m.rss, do: mib(m.rss), else: "unknown"
    Logger.warning("memory_watchdog high used_mib=#{mib(m.used)} rss_mib=#{rss} beam_mib=#{mib(m.beam)} host_mib=#{mib(m.host)}")

    %{processes: processes, unresponsive: unresponsive, ets: ets} = snapshot_fun.()
    holders = Enum.map_join(processes, ", ", fn p -> "#{p.name} #{mib(p.memory)} MiB queue=#{p.queue}" end)
    stuck = Enum.join(unresponsive, ", ")
    tables = Enum.map_join(ets, ", ", fn t -> "#{t.name} #{mib(t.memory)} MiB size=#{t.size}" end)
    Logger.warning("memory_watchdog top processes=[#{holders}] unresponsive=[#{stuck}] ets=[#{tables}]")

    [
      message: message,
      reason:
        "#{message}. Largest processes: #{holders}. Unresponsive processes: #{if stuck == "", do: "none", else: stuck}. " <>
          "Largest ETS tables: #{tables}. Restart the daemon before the host kills it, and attach these names to the memory ticket.",
      needs_attention: true,
      severity: "critical"
    ]
  end

  @doc false
  @spec snapshot(keyword()) :: %{processes: list(map()), unresponsive: [String.t()], ets: list(map())}
  def snapshot(opts \\ []) do
    names = Map.new(Process.registered(), &{Process.whereis(&1), inspect(&1)})
    timeout = Keyword.get(opts, :probe_timeout_ms, @probe_timeout_ms)
    info = Keyword.get(opts, :info_fun, &Process.info/2)

    probes =
      Keyword.get(opts, :pids, Process.list())
      |> Task.async_stream(&probe(&1, names, info), timeout: timeout, on_timeout: :kill_task, zip_input_on_exit: true, max_concurrency: 64)
      |> Enum.flat_map(fn
        {:ok, nil} -> []
        {:ok, info} -> [info]
        {:exit, {pid, _reason}} -> [{:unresponsive, Map.get(names, pid, inspect(pid))}]
      end)

    {stuck, live} = Enum.split_with(probes, &match?({:unresponsive, _}, &1))

    %{
      processes: live |> Enum.sort_by(& &1.memory, :desc) |> Enum.take(@top),
      unresponsive: Enum.map(stuck, &elem(&1, 1)),
      ets: top_tables()
    }
  end

  defp probe(pid, names, info_fun) do
    case info_fun.(pid, [:memory, :message_queue_len, :dictionary]) do
      nil -> nil
      info -> %{name: Map.get_lazy(names, pid, fn -> initial_call(pid, info) end), memory: info[:memory], queue: info[:message_queue_len]}
    end
  end

  defp initial_call(pid, info), do: inspect(Keyword.get(info[:dictionary], :"$initial_call", pid))

  defp top_tables do
    word = :erlang.system_info(:wordsize)

    :ets.all()
    |> Enum.flat_map(fn table ->
      case {:ets.info(table, :name), :ets.info(table, :size), :ets.info(table, :memory)} do
        {name, size, words} when is_integer(size) and is_integer(words) -> [%{name: inspect(name), size: size, memory: words * word}]
        _gone -> []
      end
    end)
    |> Enum.sort_by(& &1.memory, :desc)
    |> Enum.take(@top)
  end

  defp fraction do
    Aiur.Config.settings!().monitoring.daemon_memory_alert_fraction
  rescue
    _ -> @default_fraction
  end

  defp host_bytes, do: proc_kb("/proc/meminfo", ~r/MemTotal:\s+(\d+)\s*kB/)
  defp rss_bytes, do: proc_kb("/proc/self/status", ~r/VmRSS:\s+(\d+)\s*kB/)

  defp proc_kb(path, regex) do
    with {:ok, content} <- File.read(path),
         [_, kb] <- Regex.run(regex, content),
         do: String.to_integer(kb) * 1024,
         else: (_ -> nil)
  end

  defp mib(bytes), do: div(bytes, 1_048_576)
end
