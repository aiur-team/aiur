defmodule Aiur.RunTelemetry.Dataset do
  @moduledoc """
  Tolerant offline reducer for one or more durable telemetry streams.

  Parsing is line-isolated: malformed, unsupported, or partial records become
  report warnings while adjacent valid records remain usable. The reducer owns
  ordering, profile statistics, lifecycle interval pairing, and review wakeup
  diagnostics; renderers consume its backend-neutral map.
  """

  alias Aiur.RunTelemetry.Dataset.LifecycleIntervals
  alias Aiur.RunTelemetry.Dataset.Resources
  alias Aiur.RunTelemetry.Dataset.Source

  @type dataset :: map()

  @doc "Discovers, validates, and reduces telemetry inputs into report data."
  @spec build(Path.t() | [Path.t()], keyword()) ::
          {:ok, dataset()} | {:error, {:no_telemetry_files, [Path.t()]}}
  def build(inputs, opts \\ []) when is_list(opts) do
    inputs = inputs |> List.wrap() |> Enum.map(&Path.expand/1)
    files = Source.discover_files(inputs)

    if files == [] do
      {:error, {:no_telemetry_files, inputs}}
    else
      {file_records, parse_warnings} = Source.read_files(files, opts)
      {github_records, github_warnings} = Source.github_records(Keyword.get(opts, :github_events, []))

      {records, dedupe_warnings} =
        (file_records ++ github_records)
        |> Enum.sort_by(&record_sort_key/1)
        |> dedupe_records()

      sequence_warnings = sequence_warnings(file_records)
      runtime_warnings = runtime_warnings(records)
      {actors, actor_warnings} = Resources.reduce_actors(records, opts)
      {tickets, findings} = LifecycleIntervals.reduce_tickets(records, opts)

      warnings =
        parse_warnings ++
          github_warnings ++
          dedupe_warnings ++
          sequence_warnings ++
          runtime_warnings ++ actor_warnings

      {:ok,
       %{
         records: records,
         restarts: Enum.filter(records, &daemon_restart?/1),
         actors: actors,
         tickets: tickets,
         findings: findings,
         warnings: warnings,
         provenance: provenance(inputs, files, records)
       }}
    end
  end

  @doc """
  Narrows an already-reduced dataset to one session and/or one ticket set.

  Scoping the reduced dataset rather than re-reading the stream per scope keeps a
  single parse and a single interval-pairing path; only the per-actor statistics
  are recomputed, so `profile` reflects the surviving samples instead of the
  whole stream.

  Options:

    * `:boot_id` — keep only records written by that daemon boot. Live external
      GitHub anchors survive regardless: they carry no boot of their own. Historical
      reconciliation anchors are the exception; they remain in full-log reporting
      but are excluded from a boot-scoped view so they cannot inflate this session.
    * `:tickets` — a `MapSet` of bare ticket-number strings. Non-ticket actors
      (the daemon and executor baselines) are always retained; they are shared
      orchestration overhead, not per-ticket cost.

  An actor or ticket left with nothing in scope is dropped rather than kept as an
  empty shell.
  """
  @spec filter(dataset(), keyword()) :: dataset()
  def filter(dataset, opts) when is_map(dataset) and is_list(opts) do
    boot_id = Keyword.get(opts, :boot_id)
    tickets = Keyword.get(opts, :tickets)

    records = dataset |> Map.get(:records, []) |> Enum.filter(&keep_record?(&1, boot_id, tickets))
    actors = dataset |> Map.get(:actors, %{}) |> filter_actors(boot_id, tickets)
    scoped_tickets = dataset |> Map.get(:tickets, %{}) |> filter_tickets(boot_id, tickets)

    Map.merge(dataset, %{
      records: records,
      restarts: Enum.filter(records, &daemon_restart?/1),
      actors: actors,
      tickets: scoped_tickets,
      findings: dataset |> Map.get(:findings, []) |> Enum.filter(&Map.has_key?(scoped_tickets, &1.ticket)),
      provenance: rescope_provenance(Map.get(dataset, :provenance, %{}), records)
    })
  end

  @doc """
  Reduces an already-normalized record list into the `{actors, tickets,
  findings}` shape `build/2` derives from a stream. Used by `merge/1` to union
  datasets across boots so a ticket or actor active in several boots keeps
  every boot's samples/events, with intervals and profiles re-derived over the
  union.
  """
  @spec reduce([map()], keyword()) :: {map(), map(), [map()]}
  def reduce(records, opts \\ []) when is_list(records) do
    {actors, _warnings} = Resources.reduce_actors(records, opts)
    {tickets, findings} = LifecycleIntervals.reduce_tickets(records, opts)
    {actors, tickets, findings}
  end

  @doc """
  Unions already-reduced datasets into one dataset, keeping every boot's data
  for tickets and actors that appear in several boots.

  Records deduplicate by `record_id` — GitHub anchors are boot-agnostic and
  appear in every per-boot summary, so a naive concatenation would duplicate
  them — then resource samples and lifecycle events concatenate across boots
  and intervals/profiles re-derive over the union. This is the same semantics
  as the canonical Python `_rollup_build`: a multi-boot ticket keeps every
  boot's intervals and an actor keeps every boot's samples, never collapsing to
  a last-wins map merge.
  """
  @spec merge([dataset()]) :: dataset()
  def merge(datasets) when is_list(datasets) do
    records =
      datasets
      |> Enum.flat_map(& &1.records)
      |> Enum.uniq_by(& &1.record_id)
      |> Enum.sort_by(&record_sort_key/1)

    {actors, tickets, findings} = reduce(records)

    %{
      records: records,
      restarts: Enum.filter(records, &daemon_restart?/1),
      actors: actors,
      tickets: tickets,
      findings: findings,
      warnings: Enum.flat_map(datasets, & &1.warnings),
      provenance: merge_provenance(datasets)
    }
  end

  @doc "Distinct daemon boots represented in a dataset, oldest first."
  @spec boot_ids(dataset()) :: [String.t()]
  def boot_ids(dataset) when is_map(dataset) do
    dataset
    |> Map.get(:records, [])
    |> Enum.reject(&(&1.boot_id == "github"))
    |> Enum.group_by(& &1.boot_id, & &1.timestamp_ms)
    |> Enum.sort_by(fn {_boot_id, stamps} -> Enum.max(stamps, fn -> 0 end) end)
    |> Enum.map(fn {boot_id, _stamps} -> boot_id end)
  end

  defp keep_record?(record, boot_id, tickets) do
    in_boot?(record, boot_id) and in_tickets?(Map.get(record.attributes, "ticket"), tickets)
  end

  defp daemon_restart?(%{kind: "restart", attributes: %{"event" => "daemon_restart"}}), do: true
  defp daemon_restart?(_record), do: false

  defp in_boot?(_record, nil), do: true

  # A reconciliation anchor is historical evidence. It remains available to
  # full-log reporting, but must not inflate the daemon boot that reconciled it.
  defp in_boot?(%{attributes: %{"source" => "github_reconciliation"}}, _boot_id), do: false
  defp in_boot?(%{source: "github_reconciliation"}, _boot_id), do: false
  defp in_boot?(%{boot_id: "github"}, _boot_id), do: true
  defp in_boot?(%{boot_id: record_boot}, boot_id), do: record_boot == boot_id

  # A record with no ticket (a restart, a host-level warning) is scope-neutral.
  defp in_tickets?(nil, _tickets), do: true
  defp in_tickets?(_ticket, nil), do: true
  defp in_tickets?(ticket, tickets), do: MapSet.member?(tickets, ticket)

  defp filter_actors(actors, boot_id, tickets) do
    actors
    |> Enum.filter(fn {key, _actor} -> actor_in_scope?(key, tickets) end)
    |> Enum.flat_map(fn {key, actor} -> rescope_actor(key, actor, boot_id) end)
    |> Map.new()
  end

  defp actor_in_scope?(_key, nil), do: true
  defp actor_in_scope?("ticket:" <> number, tickets), do: MapSet.member?(tickets, number)
  defp actor_in_scope?(_key, _tickets), do: true

  defp rescope_actor(key, actor, nil), do: [{key, actor}]

  defp rescope_actor(key, actor, boot_id) do
    case Enum.filter(Map.get(actor, :samples, []), &(&1.boot_id == boot_id)) do
      [] ->
        []

      samples ->
        [
          {key,
           Map.merge(actor, %{
             samples: samples,
             profile: Resources.resource_profile(samples),
             gaps: Resources.resource_gaps(samples, []),
             availability: Resources.availability_counts(samples)
           })}
        ]
    end
  end

  defp filter_tickets(tickets, boot_id, ticket_set) do
    tickets
    |> Enum.filter(fn {id, _ticket} -> is_nil(ticket_set) or MapSet.member?(ticket_set, id) end)
    |> Enum.flat_map(fn {id, ticket} -> rescope_ticket(id, ticket, boot_id) end)
    |> Map.new()
  end

  defp rescope_ticket(id, ticket, nil), do: [{id, ticket}]

  defp rescope_ticket(id, ticket, boot_id) do
    case Enum.filter(Map.get(ticket, :events, []), &in_boot?(&1, boot_id)) do
      [] ->
        []

      events ->
        [{id, Map.merge(ticket, %{events: events, intervals: LifecycleIntervals.lifecycle_intervals(events)})}]
    end
  end

  defp rescope_provenance(provenance, records) do
    time_range =
      case records do
        [] -> nil
        records -> %{start: hd(records).timestamp_iso, end: List.last(records).timestamp_iso}
      end

    provenance
    |> Map.put(:time_range, time_range)
    |> Map.put(:record_count, length(records))
  end

  defp dedupe_records(records) do
    records
    |> Enum.reduce({[], MapSet.new(), MapSet.new(), []}, fn record, {kept, record_ids, event_keys, warnings} ->
      event_key = lifecycle_event_key(record)

      cond do
        MapSet.member?(record_ids, record.record_id) ->
          warning = %{type: :duplicate_record, record_id: record.record_id}
          {kept, record_ids, event_keys, [warning | warnings]}

        event_key && MapSet.member?(event_keys, event_key) ->
          {kept, MapSet.put(record_ids, record.record_id), event_keys, duplicate_boundary_warnings(record, event_key, warnings)}

        true ->
          {
            [record | kept],
            MapSet.put(record_ids, record.record_id),
            maybe_put_event_key(event_keys, event_key),
            warnings
          }
      end
    end)
    |> then(fn {kept, _record_ids, _event_keys, warnings} ->
      {Enum.reverse(kept), Enum.reverse(warnings)}
    end)
  end

  # A point carried across a segment roll replicates a record that may still be
  # in the retained prior segment; that is the writer keeping the boot's
  # completion facts, not a duplicate emission, so it collapses silently.
  defp duplicate_boundary_warnings(record, event_key, warnings) do
    if carried_point?(record),
      do: warnings,
      else: [%{type: :duplicate_lifecycle_boundary, event_key: event_key} | warnings]
  end

  defp maybe_put_event_key(event_keys, nil), do: event_keys
  defp maybe_put_event_key(event_keys, event_key), do: MapSet.put(event_keys, event_key)

  defp lifecycle_event_key(%{kind: "lifecycle", attributes: attributes} = record) do
    if Map.get(attributes, "source_id") || Map.get(attributes, "operation_id") || carried_point_event?(record) do
      Map.get(attributes, "event_key")
    end
  end

  defp lifecycle_event_key(_record), do: nil

  # The point events the writer re-emits after a segment roll (see
  # `Aiur.RunTelemetry.Writer`). Their identity is the event key, so the
  # original and its carried replica collapse to one point.
  @carried_point_events ~w(dispatch pr_opened pr_merged)

  defp carried_point_event?(%{attributes: %{"event" => event, "boundary" => "point"}}),
    do: event in @carried_point_events

  defp carried_point_event?(_record), do: false

  defp carried_point?(%{attributes: %{"segment_continuation" => "carried"}}), do: true
  defp carried_point?(_record), do: false

  defp sequence_warnings(records) do
    records
    |> Enum.reject(&(&1.boot_id == "github"))
    |> Enum.group_by(& &1.boot_id)
    |> Enum.flat_map(fn {boot_id, boot_records} ->
      boot_records
      |> Enum.sort_by(& &1.sequence)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(&sequence_gap(&1, boot_id))
    end)
    |> Enum.sort_by(&{&1.boot_id, &1.after_sequence})
  end

  defp sequence_gap([previous, current], boot_id) do
    if current.sequence > previous.sequence + 1 do
      [
        %{
          type: :sequence_gap,
          boot_id: boot_id,
          after_sequence: previous.sequence,
          before_sequence: current.sequence,
          missing_count: current.sequence - previous.sequence - 1
        }
      ]
    else
      []
    end
  end

  defp runtime_warnings(records) do
    records
    |> Enum.filter(&(&1.kind == "warning"))
    |> Enum.map(fn record ->
      %{
        type: :runtime_warning,
        timestamp: record.timestamp_iso,
        boot_id: record.boot_id,
        attributes: record.attributes
      }
    end)
  end

  # Union of per-dataset provenance for `merge/1`: sources and schema versions
  # deduplicate, record counts sum, and the time range spans every boot.
  defp merge_provenance(datasets) do
    provenances = Enum.map(datasets, & &1.provenance)

    files = provenances |> Enum.flat_map(& &1.files) |> Enum.uniq()
    inputs = provenances |> Enum.flat_map(& &1.inputs) |> Enum.uniq()
    schema_versions = provenances |> Enum.flat_map(& &1.schema_versions) |> Enum.uniq() |> Enum.sort()
    record_count = provenances |> Enum.reduce(0, &(&1.record_count + &2))

    time_range =
      case provenances |> Enum.map(& &1.time_range) |> Enum.reject(&is_nil/1) do
        [] -> nil
        ranges -> %{start: ranges |> Enum.map(& &1.start) |> Enum.min(), end: ranges |> Enum.map(& &1.end) |> Enum.max()}
      end

    %{
      inputs: inputs,
      files: files,
      schema_versions: schema_versions,
      time_range: time_range,
      record_count: record_count,
      enrich: Enum.any?(provenances, &Map.get(&1, :enrich, false)),
      generated_by: "dataset:merge"
    }
  end

  defp provenance(inputs, files, records) do
    schema_versions = records |> Enum.map(& &1.schema_version) |> Enum.uniq() |> Enum.sort()

    time_range =
      case records do
        [] -> nil
        records -> %{start: hd(records).timestamp_iso, end: List.last(records).timestamp_iso}
      end

    %{
      inputs: inputs,
      files: files,
      schema_versions: schema_versions,
      time_range: time_range,
      record_count: length(records)
    }
  end

  defp record_sort_key(record) do
    {
      record.timestamp_ms,
      record.boot_id,
      record.sequence,
      record.record_id,
      record.source_path,
      record.source_line
    }
  end
end
