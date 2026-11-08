defmodule Aiur.MemoryWatchdog do
  @moduledoc """
  Alerts once when the daemon BEAM uses more than `monitoring.daemon_memory_alert_fraction`
  of host memory, before the kernel OOM killer stops it (#7796).

  The kernel kill is SIGKILL and leaves no crash dump, so the alert names the
  processes holding the most memory at the moment it fires.
  """

  use GenServer

  require Logger

  alias Aiur.Signal

  @topic "system.daemon.memory_high"
  @interval_ms 10_000
  @default_fraction 0.5
  @top 5

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "One check: alerts on crossing above the line and resolves on falling back below it."
  @spec check(boolean(), keyword()) :: boolean()
  def check(high?, opts \\ []) do
    used = Keyword.get(opts, :used_fun, fn -> :erlang.memory(:total) end).()
    host = Keyword.get(opts, :host_fun, &host_bytes/0).()
    fraction = Keyword.get(opts, :fraction_fun, &fraction/0).()
    alert = Keyword.get(opts, :alert_fun, &Signal.alert/2)

    case {high?, is_integer(host) and used > fraction * host} do
      {false, true} ->
        alert.(@topic, high_alert(used, host, fraction, Keyword.get(opts, :top_fun, &top_processes/0).()))
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

  defp high_alert(used, host, fraction, top) do
    message = "Daemon memory #{mib(used)} MiB is above #{round(fraction * 100)}% of host memory (#{mib(host)} MiB)"
    holders = Enum.map_join(top, ", ", fn {name, bytes} -> "#{name} #{mib(bytes)} MiB" end)
    Logger.warning("memory_watchdog high used_mib=#{mib(used)} host_mib=#{mib(host)} top=#{holders}")

    [
      message: message,
      reason: "#{message}. Largest processes: #{holders}. Restart the daemon before the host kills it, and attach these names to the memory ticket.",
      needs_attention: true,
      severity: "critical"
    ]
  end

  defp top_processes do
    Process.list()
    |> Enum.flat_map(fn pid ->
      case Process.info(pid, [:memory, :registered_name, :dictionary]) do
        nil -> []
        info -> [{process_name(pid, info), info[:memory]}]
      end
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(@top)
  end

  defp process_name(pid, info) do
    case info[:registered_name] do
      name when is_atom(name) -> inspect(name)
      [] -> inspect(Keyword.get(info[:dictionary], :"$initial_call", pid))
    end
  end

  defp fraction do
    Aiur.Config.settings!().monitoring.daemon_memory_alert_fraction
  rescue
    _ -> @default_fraction
  end

  defp host_bytes do
    with {:ok, content} <- File.read("/proc/meminfo"),
         [_, kb] <- Regex.run(~r/MemTotal:\s+(\d+)\s*kB/, content),
         do: String.to_integer(kb) * 1024,
         else: (_ -> nil)
  end

  defp mib(bytes), do: div(bytes, 1_048_576)
end
