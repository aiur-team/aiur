defmodule Aiur.SaturationSentinel do
  @moduledoc """
  Daemon-side saturation diagnostics recorder (daemon crash diagnosis, #1429).

  The #852 crash killed the daemon BEAM under sustained CPU saturation and the
  retained dump is sparse: the native port-spawn helper died
  (`erl_child_setup: 104` = `ECONNRESET`) with no Erlang process or stack, so
  the dump alone cannot tell churn from an exec/pipe failure (#1484). This
  worker watches the host 1-min load and, once it crosses the per-scheduler
  escalation threshold (the #465 dispatch hard gate, default 1.5 x schedulers)
  toward the fatal zone, appends VM-internal + host diagnostics to
  `saturation.log` beside the daemon log. On the next crash the dump becomes
  interpretable against the sentinel's tail: process, port, atom, ETS, and
  run-queue counts in the seconds before death, and whether the failure
  followed a spawn/exec burst.

  Fails open by design: any probe error becomes an omitted field, writes are
  wrapped, and the recorder never raises — diagnostics can never take the
  supervision tree down. When load drops back below the threshold the worker
  disarms so a later surge starts a fresh "entered" record.
  """

  use GenServer

  require Logger

  alias Aiur.{Config, LogFile, SystemLoad}

  @default_interval_ms 5_000
  @default_cooldown_ms 30_000
  @filename "saturation.log"
  @fallback_threshold_per_scheduler 1.5

  defmodule State do
    @moduledoc false
    defstruct [
      :interval_ms,
      :cooldown_ms,
      :threshold_per_scheduler,
      :file_path,
      :snapshot_opts,
      :last_record_ms,
      armed: false
    ]
  end

  # ---------------------------------------------------------------- API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Whether the recorder is enabled (default true; config kill switch)."
  @spec enabled?() :: boolean()
  def enabled? do
    safe_config(&Config.saturation_log_enabled?/0, true)
  end

  @doc "Durable saturation diagnostics stream beside the daemon log."
  @spec file_path() :: Path.t()
  def file_path do
    log_file =
      case Application.get_env(:aiur, :log_file) do
        path when is_binary(path) and path != "" -> path
        _other -> LogFile.default_log_file()
      end

    Path.join(Path.dirname(log_file), @filename)
  end

  @doc """
  Pure diagnostics snapshot for one escalation sample.

  Injectable sources keep the shape unit-testable: pass `:load_fun` to fake a
  load value and the rest probe the live VM. Every probe is individually
  guarded so one failure never fails the sample.
  """
  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []) do
    load_fun = Keyword.get(opts, :load_fun, &SystemLoad.avg1/0)
    now_fun = Keyword.get(opts, :now_fun, &DateTime.utc_now/0)

    %{
      ts: now_fun.() |> DateTime.to_iso8601(),
      load1: safe(fn -> load_fun.() end),
      schedulers_online: safe(&:erlang.system_info/1, [:schedulers_online]),
      process_count: safe(&:erlang.system_info/1, [:process_count]),
      process_limit: safe(&:erlang.system_info/1, [:process_limit]),
      port_count: safe(&:erlang.system_info/1, [:port_count]),
      atom_count: safe(&:erlang.system_info/1, [:atom_count]),
      atom_limit: safe(&:erlang.system_info/1, [:atom_limit]),
      ets_tables: safe(fn -> length(:ets.all()) end),
      run_queue: safe(&:erlang.statistics/1, [:run_queue]),
      memory: safe(&:erlang.memory/0)
    }
  end

  @doc """
  Pure escalation decision for one sample.

  Returns:

    * `:enter`  — load crossed the threshold; start recording a fresh surge
    * `:record` — still above the threshold and past the per-surge cooldown
    * `:disarm` — load dropped back below the threshold
    * `:skip`   — no state change / load unavailable
  """
  @spec should_record?(float() | :unavailable, pos_integer(), map()) ::
          :enter | :record | :disarm | :skip
  def should_record?(load, schedulers, state) when is_integer(schedulers) and schedulers > 0 do
    %{
      threshold_per_scheduler: threshold,
      armed: armed,
      last_record_ms: last,
      cooldown_ms: cooldown,
      now_ms: now
    } = state

    case load do
      :unavailable ->
        :skip

      load when is_number(load) ->
        cond do
          load >= threshold * schedulers and not armed -> :enter
          load >= threshold * schedulers and armed and now - last >= cooldown -> :record
          load >= threshold * schedulers -> :skip
          armed -> :disarm
          true -> :skip
        end
    end
  end

  @doc "Append one JSON diagnostics line to the saturation file (fail-open)."
  @spec record(Path.t(), map()) :: :ok
  def record(path, snapshot) do
    line = Jason.encode!(Map.put(snapshot, :armed_at, DateTime.utc_now() |> DateTime.to_iso8601()))
    File.mkdir_p!(Path.dirname(path))
    File.write(path, line <> "\n", [:append])
    :ok
  rescue
    error -> Logger.warning("saturation_sentinel record_failed error=#{inspect(error)}")
  catch
    _kind, reason -> Logger.warning("saturation_sentinel record_failed caught=#{inspect(reason)}")
  end

  # --------------------------------------------------------- callbacks

  @impl true
  def init(opts) do
    unless enabled?() do
      Logger.info("saturation_sentinel disabled by config")
      {:ignore, %State{}}
    else
      state = %State{
        interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
        cooldown_ms: Keyword.get(opts, :cooldown_ms, @default_cooldown_ms),
        threshold_per_scheduler: threshold(opts),
        file_path: Keyword.get(opts, :file_path, file_path()),
        snapshot_opts: Keyword.get(opts, :snapshot_opts, []),
        last_record_ms: 0
      }

      Logger.info("saturation_sentinel armed threshold_per_scheduler=#{state.threshold_per_scheduler}")
      schedule_tick(state.interval_ms)
      {:ok, state}
    end
  end

  @impl true
  def handle_info(:tick, %State{} = state) do
    state = evaluate(state)
    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ----------------------------------------------------------- internals

  defp threshold(opts) do
    case Keyword.get(opts, :threshold_per_scheduler) do
      value when is_number(value) and value > 0 -> value
      _ -> safe_config(&Config.max_load_average/0) || @fallback_threshold_per_scheduler
    end
  end

  defp evaluate(%State{} = state) do
    now = System.monotonic_time(:millisecond)
    schedulers = System.schedulers_online()
    load = SystemLoad.avg1()

    decision =
      state
      |> Map.from_struct()
      |> Map.put(:now_ms, now)
      |> then(&should_record?(load, schedulers, &1))

    case decision do
      :enter ->
        Logger.warning(
          "saturation_sentinel entered load1=#{inspect(load)} schedulers=#{schedulers} " <>
            "threshold=#{state.threshold_per_scheduler * schedulers}"
        )

        record(state.file_path, snapshot(state.snapshot_opts))
        %{state | armed: true, last_record_ms: now}

      :record ->
        record(state.file_path, snapshot(state.snapshot_opts))
        %{state | last_record_ms: now}

      :disarm ->
        Logger.warning("saturation_sentinel disarmed load1=#{inspect(load)} schedulers=#{schedulers}")
        %{state | armed: false}

      :skip ->
        state
    end
  end

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  # Fail-open config reads: early boot or a broken workflow must never crash
  # the recorder (its whole contract is "diagnostics can't take the tree down").
  defp safe_config(fun, fallback \\ nil) do
    fun.()
  rescue
    _error -> fallback
  catch
    _kind, _reason -> fallback
  end

  defp safe(fun) do
    safe(fun, [])
  end

  defp safe(fun, args) do
    apply(fun, args)
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end
end
