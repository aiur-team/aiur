defmodule Aiur.RunTelemetry.Sampler do
  @moduledoc """
  Periodically samples mutually exclusive daemon, ticket, and Executor trees.

  Scans run in a monitored worker so the GenServer stays responsive. A cadence
  tick that arrives while a prior scan is running is recorded and skipped
  instead of queueing another full procfs walk.
  """

  use GenServer

  alias Aiur.BuildGate
  alias Aiur.Orchestrator
  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.Procfs
  alias Aiur.SystemFileDescriptors

  import Aiur.RunTelemetry.Sampler.ProcessTree, only: [successful_sample: 4, unavailable_sample: 2, safe_call: 2]

  @default_interval_ms 5_000
  @default_pressure_probe_timeout_ms 500
  @default_build_probe_cadence 5
  @fleet_fields [:fleet_agents_occupied, :fleet_agents_configured, :fleet_agents_max, :fleet_agents_effective]
  @fleet_admission_fields [:fleet_admission_signal, :fleet_load, :fleet_load_threshold, :fleet_schedulers]
  @build_fields [
    :build_gate_enabled,
    :build_gate_capacity,
    :build_gate_active,
    :build_gate_queued,
    :build_queue_oldest_wait_seconds
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc false
  @spec sample_once(map(), keyword()) :: %{
          records: [map()],
          warnings: [map()],
          previous: map(),
          build_pressure: map() | nil
        }
  def sample_once(previous, opts \\ []) when is_map(previous) and is_list(opts) do
    table_fun = Keyword.get(opts, :process_table_fun, &Procfs.process_table/0)
    {pressure, build_pressure, pressure_warnings} = pressure_observation(opts)

    context = %{
      entries: safe_entries(Keyword.get(opts, :entries_fun, &Aiur.ProcessReaper.entries/0)),
      daemon_pid: Keyword.get_lazy(opts, :daemon_pid, &current_daemon_pid/0),
      operator_pid: Keyword.get_lazy(opts, :operator_pid, &current_operator_pid/0),
      fd_headroom:
        safe_call(
          Keyword.get(opts, :fd_headroom_fun, &SystemFileDescriptors.sample/0),
          :unavailable
        ),
      now_ms: Keyword.get_lazy(opts, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end),
      clock_ticks: Keyword.get_lazy(opts, :clock_ticks_per_second, &Procfs.clock_ticks_per_second/0),
      opts: opts
    }

    result =
      case safe_call(table_fun, {:error, {:procfs_unavailable, :reader_failed}}) do
        {:ok, table, table_warnings} when is_map(table) ->
          successful_sample(previous, table, table_warnings, context)
          |> attach_pressure(pressure)

        {:error, reason} ->
          unavailable_sample(context, reason)
          |> attach_pressure(pressure)

        _other ->
          unavailable_sample(context, :invalid_process_table)
          |> attach_pressure(pressure)
      end

    result
    |> Map.put(:build_pressure, build_pressure)
    |> Map.update!(:warnings, &(&1 ++ pressure_warnings))
  end

  @impl true
  def init(opts) do
    sample_opts = Keyword.get(opts, :sample_opts, [])

    sample_opts =
      Keyword.put_new_lazy(sample_opts, :clock_ticks_per_second, fn ->
        Procfs.clock_ticks_per_second()
      end)

    sample_fun =
      Keyword.get(opts, :sample_fun, fn previous, tick_opts ->
        sample_once(previous, Keyword.merge(sample_opts, tick_opts))
      end)

    recorder = Keyword.get(opts, :recorder, &RunTelemetry.record_batch/1)

    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      sample_fun: sample_fun,
      recorder: recorder,
      previous: %{},
      scan: nil,
      tick: 0,
      last_build_pressure: nil
    }

    if Keyword.get(opts, :start_immediately?, true), do: send(self(), :tick), else: schedule_tick(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{scan: nil} = state) do
    schedule_tick(state.interval_ms)
    token = make_ref()
    parent = self()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        tick_opts = [build_probe_tick: state.tick, last_build_pressure: state.last_build_pressure]
        result = safe_sample(state.sample_fun, state.previous, tick_opts)
        send(parent, {:sample_complete, token, result})
      end)

    {:noreply, %{state | scan: %{pid: pid, monitor_ref: monitor_ref, token: token}, tick: state.tick + 1}}
  end

  def handle_info(:tick, state) do
    schedule_tick(state.interval_ms)
    record(state.recorder, [{:warning, %{event: :resource_sample_skipped, reason: :overlap}}])
    {:noreply, state}
  end

  def handle_info(
        {:sample_complete, token, %{records: records, warnings: warnings, previous: previous} = result},
        %{scan: %{monitor_ref: monitor_ref, token: token}} = state
      ) do
    Process.demonitor(monitor_ref, [:flush])
    batch = Enum.map(records, &{:resource, &1}) ++ Enum.map(warnings, &{:warning, warning_record(&1)})
    record(state.recorder, batch)
    {:noreply, %{state | previous: previous, scan: nil, last_build_pressure: result[:build_pressure] || state.last_build_pressure}}
  end

  def handle_info({:sample_complete, _token, _result}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, %{scan: %{monitor_ref: monitor_ref}} = state) do
    record(state.recorder, [{:warning, %{event: :resource_sample_failed, reason: reason}}])
    {:noreply, %{state | scan: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{scan: %{pid: pid}}) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp pressure_observation(opts) do
    system_ms_fun = Keyword.get(opts, :system_ms_fun, fn -> System.system_time(:millisecond) end)
    timeout_ms = Keyword.get(opts, :pressure_probe_timeout_ms, @default_pressure_probe_timeout_ms)
    build_probe? = build_probe_tick?(opts)

    sources =
      [{:fleet, fleet_snapshot_fun(opts), :orchestrator_unavailable}] ++
        if build_probe? do
          [{:build, Keyword.get(opts, :build_status_fun, &BuildGate.status/0), :build_gate_unavailable}]
        else
          []
        end

    {results, probe_timeouts} = bounded_pressure_probes(sources, timeout_ms)

    build =
      if build_probe? do
        build_observation(Map.fetch!(results, :build), safe_call(system_ms_fun, nil))
      else
        # The lock-scanning build probe is expensive and, on a loaded host, the
        # only one that can disturb a real acquisition, so it runs on a reduced
        # cadence. Between probes the last observed build pressure is carried
        # forward with its original observed-at timestamp rather than dropped,
        # so a reduced cadence never renders as an availability gap.
        Keyword.get(opts, :last_build_pressure) || unavailable_build("unavailable")
      end

    fleet = fleet_observation(Map.fetch!(results, :fleet))
    warnings = Enum.map(probe_timeouts, &pressure_probe_timeout_warning/1)

    {Map.merge(fleet, build), build, warnings}
  end

  defp fleet_snapshot_fun(opts) do
    Keyword.get(opts, :fleet_snapshot_fun, fn -> Orchestrator.dashboard_snapshot(Orchestrator, 100) end)
  end

  defp build_probe_tick?(opts) do
    cadence = Keyword.get(opts, :build_probe_cadence, @default_build_probe_cadence)
    tick = Keyword.get(opts, :build_probe_tick, 0)
    rem(tick, max(cadence, 1)) == 0
  end

  defp pressure_probe_timeout_warning({source, :timeout}) do
    %{event: :pressure_probe_timeout, source: source, reason: :timeout}
  end

  defp pressure_probe_timeout_warning({source, reason}), do: %{event: :pressure_probe_timeout, source: source, reason: reason}

  defp bounded_pressure_probes(sources, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    sources
    |> Task.async_stream(
      fn {source, fun, fallback} -> {source, safe_call(fun, fallback)} end,
      max_concurrency: 2,
      ordered: true,
      timeout: timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.zip(sources)
    |> Enum.reduce({%{}, []}, fn
      {{:ok, {source, result}}, {source, _fun, _fallback}}, {acc, timeouts} ->
        {Map.put(acc, source, result), timeouts}

      {{:exit, _reason}, {source, _fun, _fallback}}, {acc, timeouts} ->
        {Map.put(acc, source, :probe_timeout), [{source, :timeout} | timeouts]}
    end)
  end

  defp bounded_pressure_probes(sources, _timeout_ms),
    do: {Map.new(sources, fn {source, _fun, fallback} -> {source, fallback} end), []}

  defp fleet_observation({:current, %{capacity: capacity}, freshness})
       when is_map(capacity) and is_map(freshness) do
    fields = %{
      fleet_agents_occupied: integer_value(capacity, :occupied),
      fleet_agents_configured: integer_value(capacity, :configured),
      fleet_agents_max: integer_value(capacity, :max),
      fleet_agents_effective: integer_value(capacity, :effective)
    }

    if Enum.all?(@fleet_fields, &is_integer(Map.get(fields, &1))) do
      admission = fleet_admission(capacity)

      Map.merge(fields, admission.fields)
      |> Map.merge(%{
        fleet_capacity_status: "current",
        fleet_capacity_age_ms: integer_value(freshness, :age_ms),
        fleet_capacity_observed_at_ms: freshness_observed_at_ms(freshness),
        fleet_partial_fields: admission.partial_fields
      })
    else
      unavailable_fleet("unavailable", integer_value(freshness, :age_ms))
    end
  end

  defp fleet_observation({:stale, _snapshot, freshness}) when is_map(freshness) do
    unavailable_fleet("stale", integer_value(freshness, :age_ms), freshness_observed_at_ms(freshness))
  end

  defp fleet_observation(:snapshot_unpublished), do: unavailable_fleet("unpublished", nil)
  defp fleet_observation(_result), do: unavailable_fleet("unavailable", nil)

  # The daemon's own persisted admission decision (`capacity_hold`) names the
  # binding host-pressure signal (`:build` | `:load` | ...) with its measured
  # value and threshold, and the snapshot carries the raw load dimension beside
  # it. Sampling them lets an operator tell a build-gate-saturated fleet (queue
  # growing, load far below threshold) from a host-saturated one (load gate
  # holding dispatch) — the distinction a queue depth alone cannot make.
  defp fleet_admission(capacity) do
    hold = Map.get(capacity, :capacity_hold, Map.get(capacity, "capacity_hold"))
    signal = admission_signal(hold)

    fields = %{
      fleet_admission_signal: signal,
      fleet_load: number_value(capacity, :load),
      fleet_load_threshold: number_value(capacity, :load_threshold),
      fleet_schedulers: integer_value(capacity, :schedulers)
    }

    partial_fields =
      fields
      |> Enum.filter(fn {_key, value} -> is_nil(value) end)
      |> Enum.map(&elem(&1, 0))

    %{fields: fields, partial_fields: partial_fields}
  end

  defp admission_signal(%{signal: signal}) when is_atom(signal), do: Atom.to_string(signal)
  defp admission_signal(_hold), do: nil

  defp unavailable_fleet(status, age_ms, observed_at_ms \\ nil) do
    %{
      fleet_capacity_status: status,
      fleet_capacity_age_ms: age_ms,
      fleet_capacity_observed_at_ms: observed_at_ms,
      fleet_agents_occupied: nil,
      fleet_agents_configured: nil,
      fleet_agents_max: nil,
      fleet_agents_effective: nil,
      fleet_admission_signal: nil,
      fleet_load: nil,
      fleet_load_threshold: nil,
      fleet_schedulers: nil,
      fleet_partial_fields: @fleet_fields ++ @fleet_admission_fields
    }
  end

  defp freshness_observed_at_ms(freshness) do
    case Map.get(freshness, :observed_at, Map.get(freshness, "observed_at")) do
      %DateTime{} = observed_at ->
        DateTime.to_unix(observed_at, :millisecond)

      observed_at when is_binary(observed_at) ->
        case DateTime.from_iso8601(observed_at) do
          {:ok, parsed, _offset} -> DateTime.to_unix(parsed, :millisecond)
          _error -> nil
        end

      _other ->
        nil
    end
  end

  defp build_observation(%{degraded?: true}, _observed_at_ms), do: unavailable_build("degraded")

  defp build_observation(
         %{enabled?: enabled, capacity: capacity, active: active, queued: queued, oldest_wait_seconds: oldest_wait},
         observed_at_ms
       )
       when is_boolean(enabled) and is_integer(capacity) and capacity >= 0 and is_integer(active) and active >= 0 and
              is_integer(queued) and queued >= 0 do
    base = %{
      build_gate_enabled: enabled,
      build_gate_capacity: capacity,
      build_gate_active: active,
      build_gate_queued: queued,
      build_gate_observed_at_ms: observed_at_ms
    }

    build_measurement(base, enabled, queued, oldest_wait)
  end

  defp build_observation(_result, _observed_at_ms), do: unavailable_build("unavailable")

  defp build_measurement(base, enabled, _queued, oldest_wait) when is_integer(oldest_wait) and oldest_wait >= 0 do
    Map.merge(base, %{
      build_gate_status: if(enabled, do: "measured", else: "disabled"),
      build_queue_oldest_wait_seconds: oldest_wait,
      build_partial_fields: []
    })
  end

  defp build_measurement(base, _enabled, queued, _oldest_wait) when queued > 0 do
    Map.merge(base, %{
      build_gate_status: "partial",
      build_queue_oldest_wait_seconds: nil,
      build_partial_fields: [:build_queue_oldest_wait_seconds]
    })
  end

  defp build_measurement(_base, _enabled, _queued, _oldest_wait), do: unavailable_build("unavailable")

  defp unavailable_build(status) do
    %{
      build_gate_status: status,
      build_gate_observed_at_ms: nil,
      build_gate_enabled: nil,
      build_gate_capacity: nil,
      build_gate_active: nil,
      build_gate_queued: nil,
      build_queue_oldest_wait_seconds: nil,
      build_partial_fields: @build_fields
    }
  end

  defp attach_pressure(%{records: records} = sample, pressure) do
    records =
      Enum.map(records, fn
        %{actor: "_daemon", partial_fields: partial_fields} = record ->
          source_partial_fields = pressure.fleet_partial_fields ++ pressure.build_partial_fields

          pressure = Map.drop(pressure, [:fleet_partial_fields, :build_partial_fields])
          Map.merge(record, Map.put(pressure, :partial_fields, Enum.uniq(partial_fields ++ source_partial_fields)))

        record ->
          record
      end)

    %{sample | records: records}
  end

  defp integer_value(map, key) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key))) do
      value when is_integer(value) -> value
      _other -> nil
    end
  end

  defp number_value(map, key) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key))) do
      value when is_number(value) -> value
      _other -> nil
    end
  end

  defp warning_record(warning) when is_map(warning), do: Map.put_new(warning, :event, :resource_sample_warning)
  defp warning_record(warning), do: %{event: :resource_sample_warning, reason: warning}

  defp safe_entries(entries_fun) do
    case safe_call(entries_fun, []) do
      entries when is_list(entries) -> entries
      _other -> []
    end
  end

  defp current_daemon_pid do
    case Integer.parse(System.pid()) do
      {pid, ""} when pid > 0 -> pid
      _other -> nil
    end
  end

  defp current_operator_pid do
    case System.get_env("AIUR_OPERATOR_PID") do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {pid, ""} when pid > 0 -> pid
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp safe_sample(sample_fun, previous, tick_opts) do
    result =
      case :erlang.fun_info(sample_fun, :arity) do
        {:arity, 1} -> sample_fun.(previous)
        _arity -> sample_fun.(previous, tick_opts)
      end

    case result do
      %{records: records, warnings: warnings, previous: next_previous} = result
      when is_list(records) and is_list(warnings) and is_map(next_previous) ->
        Map.put_new(result, :build_pressure, nil)

      _other ->
        %{
          records: [],
          warnings: [%{event: :resource_sample_failed, reason: :invalid_result}],
          previous: %{},
          build_pressure: nil
        }
    end
  rescue
    error ->
      %{
        records: [],
        warnings: [%{event: :resource_sample_failed, reason: Exception.message(error)}],
        previous: %{},
        build_pressure: nil
      }
  catch
    kind, reason ->
      %{
        records: [],
        warnings: [%{event: :resource_sample_failed, reason: {kind, reason}}],
        previous: %{},
        build_pressure: nil
      }
  end

  defp record(recorder, records) do
    recorder.(records)
    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
end
