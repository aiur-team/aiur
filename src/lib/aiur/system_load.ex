defmodule Aiur.SystemLoad do
  @moduledoc """
  Reads the host's 1-minute load average so the orchestrator can hold new agent
  dispatch when the box is already saturated (#465).

  Linux via `/proc/loadavg`, macOS/FreeBSD via `sysctl vm.loadavg`. Unreadable data
  returns `:unavailable` so the load gate degrades
  open — no throttling rather than a spurious hold. The source is injectable via
  the `:loadavg_source_override` app env so tests can simulate any load without
  touching the real filesystem, following the app-env override convention used
  elsewhere (e.g. `Aiur.Os`).
  """

  @doc """
  The 1-minute load average as a float, or `:unavailable` when it cannot be read
  (missing host load source or unparseable contents).
  """
  @spec avg1() :: float() | :unavailable
  def avg1 do
    case loadavg_source().() do
      {:ok, contents} -> parse_avg1(contents)
      _other -> :unavailable
    end
  end

  @doc """
  Subtracts sampled background CPU core equivalents from host demand.
  Background means processes niced above the daemon (`Aiur.BackgroundCpu`);
  the fleet inherits the daemon's nice, so it always counts. Unknown
  background CPU leaves demand unchanged.
  """
  @spec gate_signal(number() | :unavailable, map() | :unavailable, pos_integer()) :: number() | :unavailable
  def gate_signal(demand, %{background_percent: background}, schedulers)
      when is_number(demand) and is_number(background) and background >= 0 and background <= 100,
      do: max(0.0, demand - background * schedulers / 100.0)

  def gate_signal(demand, _headroom, _schedulers), do: demand

  @doc false
  @spec discount_reason(map() | :unavailable) :: :enabled | :unavailable
  def discount_reason(%{background_percent: background}) when is_number(background) and background >= 0 and background <= 100, do: :enabled
  def discount_reason(_headroom), do: :unavailable

  @doc false
  @spec daemon_nice(map() | :unavailable) :: integer() | :unavailable
  def daemon_nice(%{daemon_nice: nice}) when is_integer(nice), do: nice
  def daemon_nice(_headroom), do: :unavailable

  @doc false
  @spec print_dispatch_sample(map() | nil) :: :ok
  def print_dispatch_sample(%{load: load, gate_signal: signal, load_sampled_at_ms: sampled_at} = capacity) when is_number(load) and is_integer(sampled_at) do
    :ok = Aiur.SystemPressure.print_sample(capacity)
    age_ms = max(0, System.monotonic_time(:millisecond) - sampled_at)
    nice = Map.get(capacity, :load_daemon_nice, :unavailable)
    nice_text = if is_integer(nice), do: " daemon_nice=#{nice}", else: ""

    reason =
      case Map.get(capacity, :load_discount_reason) do
        :enabled -> " (discounts CPU niced above the daemon)"
        _ -> " (background CPU unavailable, no discount)"
      end

    IO.puts("DISPATCH LOAD (fallback only when PSI unavailable) total=#{load} gate_signal=#{signal}#{reason}#{nice_text} sampled=#{div(age_ms, 1_000)}s ago")
  end

  def print_dispatch_sample(capacity) when is_map(capacity), do: Aiur.SystemPressure.print_sample(capacity)
  def print_dispatch_sample(_capacity), do: :ok

  @doc false
  @spec sample((-> map()), non_neg_integer()) :: map()
  def sample(read_fun, timeout_ms \\ 1_000) do
    task =
      Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn ->
        sampled_at_ms = System.monotonic_time(:millisecond)
        Map.merge(read_fun.(), %{sampled_at_ms: sampled_at_ms, sample_id: make_ref()})
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, sample} -> sample
      _unavailable -> %{load: :unavailable, cpu_snapshot: :unavailable, sampled_at_ms: nil, sample_id: nil}
    end
  end

  defp parse_avg1(contents) do
    case contents |> String.trim_leading() |> String.trim_leading("{") |> String.trim_leading() |> Float.parse() do
      {value, _rest} -> value
      :error -> :unavailable
    end
  end

  defp loadavg_source do
    Application.get_env(:aiur, :loadavg_source_override, &host_load/0)
  end

  defp host_load do
    case :os.type() do
      {:unix, platform} when platform in [:darwin, :freebsd] ->
        case System.cmd("sysctl", ["-n", "vm.loadavg"], stderr_to_stdout: true) do
          {contents, 0} -> {:ok, contents}
          _ -> {:error, :unavailable}
        end

      _ ->
        File.read("/proc/loadavg")
    end
  rescue
    error in ErlangError -> {:error, error.original}
  end
end
