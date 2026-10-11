defmodule Aiur.RunTelemetry.Sampler.ProcessTree do
  @moduledoc "Attributes the process table to daemon, ticket, and Executor actor trees and builds their resource records for `Aiur.RunTelemetry.Sampler`."

  alias Aiur.RunTelemetry.Procfs

  @metric_fields [:rss_bytes, :fd_count, :read_bytes, :write_bytes]

  @typep pid_set :: MapSet.t(pos_integer())

  @doc false
  @spec successful_sample(map(), map(), [map()], map()) :: %{records: [map()], warnings: [map()], previous: map()}
  def successful_sample(previous, table, table_warnings, context) do
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
      warnings: summarize_unreadable(table_warnings ++ measurement_warnings) ++ attribution_warnings,
      previous: previous_measurements(measurements, now_ms)
    }
  end

  # Retry reads for recovery, but bound unreadable diagnostics to one record per scan.
  defp summarize_unreadable(warnings) do
    {unreadable, other} = Enum.split_with(warnings, &unreadable_warning?/1)

    case unreadable do
      [] -> other
      warnings -> other ++ [unreadable_summary(warnings)]
    end
  end

  defp unreadable_warning?(%{pid: pid, field: _field, reason: reason})
       when is_integer(pid) and reason in [:eacces, :unavailable],
       do: true

  defp unreadable_warning?(_warning), do: false

  defp unreadable_summary(warnings) do
    counts =
      warnings
      |> Enum.frequencies_by(&{&1.field, &1.reason})
      |> Enum.sort()
      |> Enum.map(fn {{field, reason}, count} -> %{field: field, reason: reason, count: count} end)

    %{field: :procfs, pid: nil, reason: :unreadable_fields, count: length(warnings), counts: counts}
  end

  @doc false
  @spec unavailable_sample(map(), term()) :: %{records: [map()], warnings: [map()], previous: map()}
  def unavailable_sample(context, reason) do
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

  defp metadata_value(metadata, key), do: Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))

  @doc false
  @spec safe_call((-> result), fallback) :: result | fallback when result: term(), fallback: term()
  def safe_call(fun, fallback) do
    fun.()
  rescue
    _error -> fallback
  catch
    :exit, _reason -> fallback
    _kind, _reason -> fallback
  end
end
