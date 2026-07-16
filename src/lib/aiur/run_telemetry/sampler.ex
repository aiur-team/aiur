defmodule Aiur.RunTelemetry.Sampler do
  @moduledoc """
  Periodically samples mutually exclusive daemon, ticket, and Executor trees.

  Scans run in a monitored worker so the GenServer stays responsive. A cadence
  tick that arrives while a prior scan is running is recorded and skipped
  instead of queueing another full procfs walk.
  """

  use GenServer

  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.Procfs
  alias Aiur.SystemFileDescriptors

  @default_interval_ms 5_000
  @metric_fields [:rss_bytes, :fd_count, :read_bytes, :write_bytes]

  @typep pid_set :: MapSet.t(pos_integer())

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc false
  @spec sample_once(map(), keyword()) :: %{records: [map()], warnings: [map()], previous: map()}
  def sample_once(previous, opts \\ []) when is_map(previous) and is_list(opts) do
    table_fun = Keyword.get(opts, :process_table_fun, &Procfs.process_table/0)

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

    case safe_call(table_fun, {:error, {:procfs_unavailable, :reader_failed}}) do
      {:ok, table, table_warnings} when is_map(table) ->
        successful_sample(previous, table, table_warnings, context)

      {:error, reason} ->
        unavailable_sample(context, reason)

      _other ->
        unavailable_sample(context, :invalid_process_table)
    end
  end

  @impl true
  def init(opts) do
    sample_opts = Keyword.get(opts, :sample_opts, [])

    sample_opts =
      Keyword.put_new_lazy(sample_opts, :clock_ticks_per_second, fn ->
        Procfs.clock_ticks_per_second()
      end)

    sample_fun = Keyword.get(opts, :sample_fun, fn previous -> sample_once(previous, sample_opts) end)
    recorder = Keyword.get(opts, :recorder, &RunTelemetry.record_batch/1)

    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      sample_fun: sample_fun,
      recorder: recorder,
      previous: %{},
      scan: nil
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
        result = safe_sample(state.sample_fun, state.previous)
        send(parent, {:sample_complete, token, result})
      end)

    {:noreply, %{state | scan: %{pid: pid, monitor_ref: monitor_ref, token: token}}}
  end

  def handle_info(:tick, state) do
    schedule_tick(state.interval_ms)
    record(state.recorder, [{:warning, %{event: :resource_sample_skipped, reason: :overlap}}])
    {:noreply, state}
  end

  def handle_info(
        {:sample_complete, token, %{records: records, warnings: warnings, previous: previous}},
        %{scan: %{monitor_ref: monitor_ref, token: token}} = state
      ) do
    Process.demonitor(monitor_ref, [:flush])
    batch = Enum.map(records, &{:resource, &1}) ++ Enum.map(warnings, &{:warning, warning_record(&1)})
    record(state.recorder, batch)
    {:noreply, %{state | previous: previous, scan: nil}}
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

  defp successful_sample(previous, table, table_warnings, context) do
    %{
      entries: entries,
      daemon_pid: daemon_pid,
      operator_pid: operator_pid,
      fd_headroom: fd_headroom,
      now_ms: now_ms,
      clock_ticks: clock_ticks,
      opts: opts
    } = context

    {actors, attribution_warnings} = actor_specs(table, entries, daemon_pid, operator_pid)
    pids = actors |> Enum.flat_map(&MapSet.to_list(&1.pids)) |> MapSet.new()
    measure_fun = Keyword.get(opts, :measure_fun, &Procfs.measure_many/2)

    {measurements, measurement_warnings} =
      case safe_call(
             fn -> measure_fun.(table, pids) end,
             {:ok, %{}, [%{field: :procfs, reason: :measurement_failed}]}
           ) do
        {:ok, measured, warnings} when is_map(measured) and is_list(warnings) -> {measured, warnings}
        _other -> {%{}, [%{field: :procfs, reason: :invalid_measurement}]}
      end

    records =
      Enum.map(
        actors,
        &actor_record(&1, measurements, previous, now_ms, clock_ticks, fd_headroom)
      )

    %{
      records: records,
      warnings: table_warnings ++ attribution_warnings ++ measurement_warnings,
      previous: previous_measurements(measurements, now_ms)
    }
  end

  defp unavailable_sample(context, reason) do
    %{entries: entries, daemon_pid: daemon_pid, operator_pid: operator_pid, fd_headroom: fd_headroom} =
      context

    {actors, attribution_warnings} = actor_specs(%{}, entries, daemon_pid, operator_pid)

    %{
      records: Enum.map(actors, &unavailable_record(&1, fd_headroom)),
      warnings: [%{event: :procfs_unavailable, reason: reason} | attribution_warnings],
      previous: %{}
    }
  end

  @spec actor_specs(map(), list(), integer() | nil, integer() | nil) :: {[map()], [map()]}
  defp actor_specs(table, entries, daemon_pid, operator_pid) do
    children = children_index(table)
    {tickets, ticket_claims, ticket_warnings} = ticket_specs(table, children, entries)

    daemon_tree = tree_for_roots(table, children, [daemon_pid])
    daemon_pids = MapSet.difference(daemon_tree, ticket_claims)

    daemon =
      measured_or_unavailable("_daemon", "daemon", nil, daemon_pid, daemon_pids, :daemon_process_unavailable, %{})

    daemon_claims = MapSet.union(ticket_claims, daemon_pids)
    operator_tree = tree_for_roots(table, children, [operator_pid])
    operator_pids = MapSet.difference(operator_tree, daemon_claims)

    operator_reason = if is_integer(operator_pid), do: :operator_process_unavailable, else: :operator_pid_unavailable

    operator =
      measured_or_unavailable("_operator", "operator", nil, operator_pid, operator_pids, operator_reason, %{})

    {[daemon | tickets] ++ [operator], ticket_warnings}
  end

  @spec ticket_specs(map(), map(), list()) :: {[map()], pid_set(), [map()]}
  defp ticket_specs(table, children, entries) do
    entries
    |> Enum.flat_map(&ticket_entry/1)
    |> Enum.group_by(& &1.ticket)
    |> Enum.sort_by(fn {ticket, _entries} -> ticket end)
    |> Enum.reduce({[], MapSet.new(), []}, fn {ticket, ticket_entries}, {specs, claimed, warnings} ->
      local_entries = Enum.reject(ticket_entries, & &1.remote)
      remote? = local_entries == [] and Enum.any?(ticket_entries, & &1.remote)
      roots = Enum.map(local_entries, & &1.pid)
      pids = table |> tree_for_roots(children, roots) |> MapSet.difference(claimed)

      metadata = %{
        backends: ticket_entries |> Enum.map(& &1.backend) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort(),
        worker_hosts:
          ticket_entries
          |> Enum.map(& &1.worker_host)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.sort()
      }

      spec =
        cond do
          remote? ->
            unavailable_spec("ticket:#{ticket}", "ticket", ticket, roots, :remote_worker, metadata)

          MapSet.size(pids) == 0 ->
            unavailable_spec(
              "ticket:#{ticket}",
              "ticket",
              ticket,
              roots,
              :process_root_unavailable,
              metadata
            )

          true ->
            measured_spec("ticket:#{ticket}", "ticket", ticket, roots, pids, metadata)
        end

      warning =
        if not remote? and roots != [] and MapSet.size(pids) == 0 do
          [%{event: :ticket_roots_unavailable, ticket: ticket}]
        else
          []
        end

      {[spec | specs], MapSet.union(claimed, pids), warning ++ warnings}
    end)
    |> then(fn {specs, claimed, warnings} -> {Enum.reverse(specs), claimed, Enum.reverse(warnings)} end)
  end

  defp ticket_entry({{:os_pid, pid}, :agent, metadata}) when is_integer(pid) and pid > 0 and is_map(metadata) do
    case metadata_value(metadata, :ticket) do
      ticket when is_binary(ticket) and ticket != "" ->
        [
          %{
            pid: pid,
            ticket: ticket,
            backend: metadata_value(metadata, :backend),
            worker_host: metadata_value(metadata, :worker_host),
            remote: metadata_value(metadata, :remote) == true
          }
        ]

      _other ->
        []
    end
  end

  defp ticket_entry(_entry), do: []

  defp measured_or_unavailable(actor, actor_type, ticket, root, pids, reason, metadata) do
    if MapSet.size(pids) > 0 do
      measured_spec(actor, actor_type, ticket, [root], pids, metadata)
    else
      unavailable_spec(actor, actor_type, ticket, [root], reason, metadata)
    end
  end

  defp measured_spec(actor, actor_type, ticket, roots, pids, metadata) do
    Map.merge(metadata, %{
      actor: actor,
      actor_type: actor_type,
      ticket: ticket,
      availability: "measured",
      unavailable_reason: nil,
      root_pids: Enum.filter(roots, &is_integer/1),
      pids: pids
    })
  end

  defp unavailable_spec(actor, actor_type, ticket, roots, reason, metadata) do
    Map.merge(metadata, %{
      actor: actor,
      actor_type: actor_type,
      ticket: ticket,
      availability: "unavailable",
      unavailable_reason: Atom.to_string(reason),
      root_pids: Enum.filter(roots, &is_integer/1),
      pids: MapSet.new()
    })
  end

  defp actor_record(
         %{availability: "unavailable"} = actor,
         _measurements,
         _previous,
         _now_ms,
         _clock_ticks,
         fd_headroom
       ) do
    unavailable_record(actor, fd_headroom)
  end

  defp actor_record(actor, measurements, previous, now_ms, clock_ticks, fd_headroom) do
    processes = actor.pids |> Enum.flat_map(&process_for(&1, measurements))

    if processes == [] do
      actor = %{
        actor
        | availability: "unavailable",
          unavailable_reason: "process_measurement_unavailable"
      }

      unavailable_record(actor, fd_headroom)
    else
      base = actor_base(actor, length(processes))

      base
      |> Map.merge(%{
        rss_bytes: sum_field(processes, :rss_bytes),
        fd_count: sum_field(processes, :fd_count),
        read_bytes: sum_field(processes, :read_bytes),
        write_bytes: sum_field(processes, :write_bytes),
        cpu_percent: rate(processes, previous, :cpu_ticks, now_ms, clock_ticks),
        read_bytes_per_second: rate(processes, previous, :read_bytes, now_ms, 1),
        write_bytes_per_second: rate(processes, previous, :write_bytes, now_ms, 1),
        partial_fields: partial_fields(processes)
      })
      |> attach_fd_headroom(actor, fd_headroom)
    end
  end

  defp unavailable_record(actor, fd_headroom) do
    actor
    |> actor_base(0)
    |> Map.merge(%{
      rss_bytes: nil,
      fd_count: nil,
      read_bytes: nil,
      write_bytes: nil,
      cpu_percent: nil,
      read_bytes_per_second: nil,
      write_bytes_per_second: nil,
      partial_fields: @metric_fields
    })
    |> attach_fd_headroom(actor, fd_headroom)
  end

  defp actor_base(actor, process_count) do
    actor
    |> Map.drop([:pids])
    |> Map.put(:process_count, process_count)
  end

  defp attach_fd_headroom(record, %{actor_type: "daemon"}, fd_headroom) when is_map(fd_headroom) do
    Map.merge(record, %{system_fd: fd_headroom, system_fd_status: "measured"})
  end

  defp attach_fd_headroom(record, %{actor_type: "daemon"}, :exhausted) do
    Map.merge(record, %{system_fd: nil, system_fd_status: "exhausted"})
  end

  defp attach_fd_headroom(record, %{actor_type: "daemon"}, _unavailable) do
    Map.merge(record, %{system_fd: nil, system_fd_status: "unavailable"})
  end

  defp attach_fd_headroom(record, _actor, _fd_headroom), do: record

  defp sum_field(processes, field) do
    values = processes |> Enum.map(&Map.get(&1, field)) |> Enum.filter(&is_number/1)
    if values == [], do: nil, else: Enum.sum(values)
  end

  defp partial_fields(processes) do
    Enum.filter(@metric_fields, fn field ->
      Enum.count(processes, &is_number(Map.get(&1, field))) < length(processes)
    end)
  end

  defp rate(_processes, _previous, :cpu_ticks, _now_ms, clock_ticks) when not is_integer(clock_ticks), do: nil

  defp rate(processes, previous, field, now_ms, divisor) do
    rates =
      Enum.flat_map(
        processes,
        &process_rate(&1, previous, field, now_ms, divisor)
      )

    if rates == [], do: nil, else: Enum.sum(rates)
  end

  defp process_rate(process, previous, field, now_ms, divisor) do
    key = {process.pid, process.start_time_ticks}

    with %{observed_ms: observed_ms} = prior <- Map.get(previous, key),
         current when is_number(current) <- Map.get(process, field),
         old when is_number(old) <- Map.get(prior, field),
         delta when delta >= 0 <- current - old,
         elapsed_ms when elapsed_ms > 0 <- now_ms - observed_ms do
      [delta / divisor / (elapsed_ms / 1_000) * rate_scale(field)]
    else
      _other -> []
    end
  end

  defp rate_scale(:cpu_ticks), do: 100.0
  defp rate_scale(_field), do: 1.0

  defp previous_measurements(measurements, now_ms) do
    measurements
    |> Map.values()
    |> Map.new(fn process ->
      key = {process.pid, process.start_time_ticks}

      {key,
       %{
         cpu_ticks: process.cpu_ticks,
         read_bytes: process.read_bytes,
         write_bytes: process.write_bytes,
         observed_ms: now_ms
       }}
    end)
  end

  defp process_for(pid, measurements) do
    case Map.get(measurements, pid) do
      process when is_map(process) -> [process]
      _other -> []
    end
  end

  defp children_index(table) do
    Enum.reduce(table, %{}, fn {pid, process}, children -> Map.update(children, process.ppid, [pid], &[pid | &1]) end)
  end

  @spec tree_for_roots(map(), map(), [term()]) :: pid_set()
  defp tree_for_roots(table, children, roots) when is_map(table) do
    roots
    |> Enum.filter(&Map.has_key?(table, &1))
    |> expand_tree(children, %{})
    |> Map.keys()
    |> MapSet.new()
  end

  @spec expand_tree([term()], map(), map()) :: map()
  defp expand_tree([], _children, seen), do: seen

  defp expand_tree([pid | rest], children, seen) do
    if Map.has_key?(seen, pid) do
      expand_tree(rest, children, seen)
    else
      expand_tree(Map.get(children, pid, []) ++ rest, children, Map.put(seen, pid, true))
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

  defp metadata_value(metadata, key), do: Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))

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

  defp safe_sample(sample_fun, previous) do
    case sample_fun.(previous) do
      %{records: records, warnings: warnings, previous: next_previous} = result
      when is_list(records) and is_list(warnings) and is_map(next_previous) ->
        result

      _other ->
        %{
          records: [],
          warnings: [%{event: :resource_sample_failed, reason: :invalid_result}],
          previous: %{}
        }
    end
  rescue
    error ->
      %{
        records: [],
        warnings: [%{event: :resource_sample_failed, reason: Exception.message(error)}],
        previous: %{}
      }
  catch
    kind, reason ->
      %{
        records: [],
        warnings: [%{event: :resource_sample_failed, reason: {kind, reason}}],
        previous: %{}
      }
  end

  defp safe_call(fun, fallback) do
    fun.()
  rescue
    _error -> fallback
  catch
    :exit, _reason -> fallback
    _kind, _reason -> fallback
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
