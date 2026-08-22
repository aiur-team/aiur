defmodule Aiur.RunTelemetry.Dataset do
  @moduledoc """
  Tolerant offline reducer for one or more durable telemetry streams.

  Parsing is line-isolated: malformed, unsupported, or partial records become
  report warnings while adjacent valid records remain usable. The reducer owns
  ordering, profile statistics, lifecycle interval pairing, and review wakeup
  diagnostics; renderers consume its backend-neutral map.
  """

  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.Lifecycle

  @telemetry_filename "telemetry.ndjson"
  @supported_kinds ~w(restart lifecycle resource warning)
  @resource_metrics ~w(
    cpu_percent rss_bytes fd_count read_bytes write_bytes
    read_bytes_per_second write_bytes_per_second
    system_fd_used system_fd_limit system_fd_available system_fd_headroom_ratio
    fleet_agents_occupied fleet_agents_configured fleet_agents_max fleet_agents_effective
    build_gate_capacity build_gate_active build_gate_queued build_queue_oldest_wait_seconds
  )
  @resource_evidence ~w(
    fleet_capacity_status fleet_capacity_age_ms fleet_capacity_observed_at_ms
    build_gate_enabled build_gate_status build_gate_observed_at_ms
  )a
  @default_sample_interval_ms 5_000
  @default_gap_threshold_multiplier 1.5
  @default_review_resume_grace_seconds 300
  @tail_chunk_bytes 64 * 1024
  @max_tail_line_bytes 1 * 1024 * 1024

  @type dataset :: map()

  @doc "Discovers, validates, and reduces telemetry inputs into report data."
  @spec build(Path.t() | [Path.t()], keyword()) ::
          {:ok, dataset()} | {:error, {:no_telemetry_files, [Path.t()]}}
  def build(inputs, opts \\ []) when is_list(opts) do
    inputs = inputs |> List.wrap() |> Enum.map(&Path.expand/1)
    files = discover_files(inputs)

    if files == [] do
      {:error, {:no_telemetry_files, inputs}}
    else
      {file_records, parse_warnings} = read_files(files, opts)
      {github_records, github_warnings} = github_records(Keyword.get(opts, :github_events, []))

      {records, dedupe_warnings} =
        (file_records ++ github_records)
        |> Enum.sort_by(&record_sort_key/1)
        |> dedupe_records()

      sequence_warnings = sequence_warnings(file_records)
      runtime_warnings = runtime_warnings(records)
      {actors, actor_warnings} = reduce_actors(records, opts)
      {tickets, findings} = reduce_tickets(records, opts)

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
    {actors, _warnings} = reduce_actors(records, opts)
    {tickets, findings} = reduce_tickets(records, opts)
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
             profile: resource_profile(samples),
             gaps: resource_gaps(samples, []),
             availability: availability_counts(samples)
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
        [{id, Map.merge(ticket, %{events: events, intervals: lifecycle_intervals(events)})}]
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

  defp discover_files(inputs) do
    inputs
    |> Enum.flat_map(fn input ->
      cond do
        File.regular?(input) ->
          [input]

        File.dir?(input) ->
          Path.wildcard(Path.join([input, "**", @telemetry_filename]), match_dot: true)

        true ->
          []
      end
    end)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp read_files(files, opts) do
    Enum.reduce(files, {[], []}, fn file, {records, warnings} ->
      {file_records, file_warnings} = read_file(file, opts)
      {file_records ++ records, file_warnings ++ warnings}
    end)
    |> then(fn {records, warnings} -> {Enum.reverse(records), Enum.reverse(warnings)} end)
  end

  defp read_file(file, opts) do
    if Keyword.get(opts, :session) == :current do
      read_current_file(file, Keyword.get(opts, :boot_id))
    else
      read_full_file(file)
    end
  end

  defp read_full_file(file) do
    file
    |> File.stream!(:line, [])
    |> Stream.with_index(1)
    |> Enum.reduce({[], []}, fn {line, line_number}, {records, warnings} ->
      case parse_line(line, file, line_number) do
        {:ok, record} -> {[record | records], warnings}
        {:warning, warning} -> {records, [warning | warnings]}
      end
    end)
  rescue
    error ->
      {[], [%{type: :file_read_error, path: file, reason: exception_class(error)}]}
  end

  # The current-session view is normally the tail boot. Read backward in bounded
  # chunks until a different boot id or the prior segment boundary appears, then
  # feed only those lines through the ordinary validator/reducer. Historical
  # boots and earlier same-boot segments are never decoded here.
  defp read_current_file(file, requested_boot_id) do
    case File.open(file, [:read, :binary]) do
      {:ok, device} ->
        try do
          case :file.position(device, :eof) do
            {:ok, size} ->
              state =
                read_tail_chunks(
                  device,
                  size,
                  "",
                  %{
                    boot_id: nil,
                    lines: [],
                    done?: false,
                    segment_boundaries: 0,
                    tail_line_too_large?: false
                  },
                  requested_boot_id
                )

              {records, warnings} =
                state.lines
                |> Enum.with_index(1)
                |> Enum.reduce({[], []}, fn {line, line_number}, {records, warnings} ->
                  case parse_line(line, file, line_number) do
                    {:ok, record} -> {[record | records], warnings}
                    {:warning, warning} -> {records, [warning | warnings]}
                  end
                end)

              warnings =
                if state.tail_line_too_large? do
                  [
                    %{type: :tail_line_too_large, path: file, max_bytes: @max_tail_line_bytes}
                    | warnings
                  ]
                else
                  warnings
                end

              {Enum.reverse(records), Enum.reverse(warnings)}

            {:error, reason} ->
              {[], [%{type: :file_read_error, path: file, reason: reason}]}
          end
        after
          File.close(device)
        end

      {:error, reason} ->
        {[], [%{type: :file_read_error, path: file, reason: reason}]}
    end
  rescue
    error -> {[], [%{type: :file_read_error, path: file, reason: exception_class(error)}]}
  end

  defp read_tail_chunks(_device, _offset, _carry, %{done?: true} = state, _requested_boot_id),
    do: state

  defp read_tail_chunks(device, offset, carry, state, requested_boot_id) do
    bytes = min(offset, @tail_chunk_bytes)
    next_offset = offset - bytes
    {:ok, _position} = :file.position(device, next_offset)

    case :file.read(device, bytes) do
      {:ok, chunk} ->
        {next_carry, lines} = split_tail_chunk(chunk <> carry, next_offset == 0)
        {oversized_lines, lines} = Enum.split_with(lines, &(byte_size(&1) > @max_tail_line_bytes))
        state = consume_tail_lines(Enum.reverse(lines), state, requested_boot_id)
        state = mark_oversized_tail_line(state, next_carry, oversized_lines)

        if next_offset == 0 or state.done? or state.tail_line_too_large? do
          state
        else
          read_tail_chunks(device, next_offset, next_carry, state, requested_boot_id)
        end

      :eof ->
        state

      {:error, _reason} ->
        state
    end
  end

  defp split_tail_chunk(data, first_chunk?) do
    lines = String.split(data, "\n", trim: false)
    lines = if String.ends_with?(data, "\n"), do: Enum.drop(lines, -1), else: lines

    if first_chunk? do
      {"", lines}
    else
      case lines do
        [] -> {"", []}
        [carry | complete] -> {carry, complete}
      end
    end
  end

  defp mark_oversized_tail_line(state, carry, oversized_lines) do
    if byte_size(carry) > @max_tail_line_bytes or oversized_lines != [] do
      Map.put(state, :tail_line_too_large?, true)
    else
      state
    end
  end

  defp consume_tail_lines(lines, state, requested_boot_id) do
    Enum.reduce_while(lines, state, &consume_tail_line(&1, &2, requested_boot_id))
  end

  defp consume_tail_line(line, %{boot_id: nil} = state, requested_boot_id) do
    boot_id = boot_id_from_line(line)
    chosen_boot_id = if boot_id == requested_boot_id, do: requested_boot_id, else: boot_id
    continue_tail_line(line, %{state | boot_id: chosen_boot_id, lines: [line | state.lines]})
  end

  defp consume_tail_line(line, state, _requested_boot_id) do
    case boot_id_from_line(line) do
      nil ->
        {:cont, %{state | lines: [line | state.lines]}}

      boot_id when boot_id == state.boot_id ->
        continue_tail_line(line, %{state | lines: [line | state.lines]})

      _other ->
        {:halt, %{state | done?: true}}
    end
  end

  defp continue_tail_line(line, state) do
    if segment_boundary_line?(line) do
      state = %{state | segment_boundaries: state.segment_boundaries + 1}

      if state.segment_boundaries >= 2,
        do: {:halt, %{state | done?: true}},
        else: {:cont, state}
    else
      {:cont, state}
    end
  end

  defp segment_boundary_line?(line) do
    match?(
      {:ok, %{"kind" => "restart", "attributes" => %{"event" => "segment_boundary"}}},
      Jason.decode(line)
    )
  end

  defp boot_id_from_line(line) do
    case Jason.decode(line) do
      {:ok, %{"boot_id" => boot_id}} when is_binary(boot_id) -> boot_id
      _other -> nil
    end
  end

  defp parse_line(line, path, line_number) do
    case Jason.decode(line) do
      {:ok, decoded} when is_map(decoded) -> validate_record(decoded, path, line_number)
      {:ok, _other} -> {:warning, warning(:invalid_record, path, line_number)}
      {:error, _reason} -> {:warning, warning(:malformed_line, path, line_number)}
    end
  end

  defp validate_record(decoded, path, line_number) do
    schema_version = Map.get(decoded, "schema_version")

    cond do
      not supported_schema_version?(schema_version) ->
        {:warning,
         warning(:unsupported_schema, path, line_number, %{
           schema_version: schema_version
         })}

      missing = missing_required_fields(decoded) ->
        {:warning, warning(:missing_fields, path, line_number, %{fields: missing})}

      Map.get(decoded, "kind") not in @supported_kinds ->
        {:warning,
         warning(:unknown_kind, path, line_number, %{
           kind: Map.get(decoded, "kind")
         })}

      true ->
        normalize_record(decoded, path, line_number)
    end
  end

  defp supported_schema_version?(schema_version) when is_integer(schema_version),
    do: schema_version in 1..RunTelemetry.schema_version()

  defp supported_schema_version?(_schema_version), do: false

  defp missing_required_fields(decoded) do
    required = ~w(kind timestamp boot_id sequence record_id attributes)
    missing = Enum.reject(required, &Map.has_key?(decoded, &1))

    cond do
      missing != [] -> missing
      not is_binary(decoded["kind"]) -> ["kind"]
      not is_binary(decoded["timestamp"]) -> ["timestamp"]
      not is_binary(decoded["boot_id"]) -> ["boot_id"]
      not is_integer(decoded["sequence"]) -> ["sequence"]
      not is_binary(decoded["record_id"]) -> ["record_id"]
      not is_map(decoded["attributes"]) -> ["attributes"]
      true -> nil
    end
  end

  defp normalize_record(decoded, path, line_number) do
    case parse_timestamp(decoded["timestamp"]) do
      {:ok, timestamp} ->
        {:ok,
         %{
           schema_version: decoded["schema_version"],
           kind: decoded["kind"],
           timestamp: timestamp,
           timestamp_iso: DateTime.to_iso8601(timestamp),
           timestamp_ms: DateTime.to_unix(timestamp, :millisecond),
           recorded_at: decoded["recorded_at"],
           boot_id: decoded["boot_id"],
           sequence: decoded["sequence"],
           record_id: decoded["record_id"],
           attributes: decoded["attributes"],
           source_path: path,
           source_line: line_number
         }}

      :error ->
        {:warning, warning(:invalid_timestamp, path, line_number)}
    end
  end

  defp parse_timestamp(%DateTime{} = timestamp), do: {:ok, timestamp}

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      _other -> :error
    end
  end

  defp parse_timestamp(_timestamp), do: :error

  defp github_records(events) when is_list(events) do
    events
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {event, sequence}, {records, warnings} ->
      case github_record(event, sequence) do
        {:ok, record} -> {[record | records], warnings}
        {:warning, warning} -> {records, [warning | warnings]}
        :skip -> {records, warnings}
      end
    end)
    |> then(fn {records, warnings} -> {Enum.reverse(records), Enum.reverse(warnings)} end)
  end

  defp github_records(_events), do: {[], [%{type: :invalid_github_events}]}

  defp github_record(event, sequence) do
    with {:ok, attributes, timestamp} <- Lifecycle.external_anchor(event),
         {:ok, parsed} <- parse_timestamp(timestamp) do
      source_id = Map.get(attributes, :source_id) || "event:#{sequence}"

      {:ok,
       %{
         schema_version: RunTelemetry.schema_version(),
         kind: "lifecycle",
         timestamp: parsed,
         timestamp_iso: DateTime.to_iso8601(parsed),
         timestamp_ms: DateTime.to_unix(parsed, :millisecond),
         recorded_at: nil,
         boot_id: "github",
         sequence: sequence,
         record_id: "github:#{source_id}",
         attributes: stringify_keys(attributes),
         source_path: "(github)",
         source_line: sequence
       }}
    else
      :skip -> :skip
      :error -> {:warning, %{type: :invalid_github_timestamp, source_index: sequence}}
    end
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
          warning = %{type: :duplicate_lifecycle_boundary, event_key: event_key}
          {kept, MapSet.put(record_ids, record.record_id), event_keys, [warning | warnings]}

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

  defp maybe_put_event_key(event_keys, nil), do: event_keys
  defp maybe_put_event_key(event_keys, event_key), do: MapSet.put(event_keys, event_key)

  defp lifecycle_event_key(%{kind: "lifecycle", attributes: attributes}) do
    if Map.get(attributes, "source_id") || Map.get(attributes, "operation_id") do
      Map.get(attributes, "event_key")
    end
  end

  defp lifecycle_event_key(_record), do: nil

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

  defp reduce_actors(records, opts) do
    resources = Enum.filter(records, &(&1.kind == "resource"))

    {valid, warnings} =
      Enum.reduce(resources, {[], []}, fn record, {valid, warnings} ->
        case Map.get(record.attributes, "actor") do
          actor when is_binary(actor) and actor != "" ->
            {[record | valid], warnings}

          _other ->
            {valid, [%{type: :resource_actor_missing, record_id: record.record_id} | warnings]}
        end
      end)

    actors =
      valid
      |> Enum.reverse()
      |> Enum.group_by(&Map.fetch!(&1.attributes, "actor"))
      |> Map.new(fn {actor, actor_records} ->
        samples = Enum.map(actor_records, &resource_sample/1)

        {actor,
         %{
           actor: actor,
           actor_type: actor_records |> List.first() |> then(&Map.get(&1.attributes, "actor_type")),
           samples: samples,
           profile: resource_profile(samples),
           gaps: resource_gaps(samples, opts),
           availability: availability_counts(samples)
         }}
      end)

    {actors, Enum.reverse(warnings)}
  end

  defp resource_sample(record) do
    metrics =
      @resource_metrics
      |> Map.new(fn metric -> {metric, resource_metric(record.attributes, metric)} end)

    evidence =
      @resource_evidence
      |> Map.new(fn field -> {field, Map.get(record.attributes, Atom.to_string(field))} end)

    metrics
    |> Map.merge(evidence)
    |> Map.merge(%{
      actor: record.attributes["actor"],
      actor_type: record.attributes["actor_type"],
      ticket: record.attributes["ticket"],
      availability: record.attributes["availability"] || "unavailable",
      unavailable_reason: record.attributes["unavailable_reason"],
      process_count: record.attributes["process_count"],
      partial_fields: record.attributes["partial_fields"] || [],
      timestamp: record.timestamp_iso,
      timestamp_ms: record.timestamp_ms,
      boot_id: record.boot_id,
      record_id: record.record_id
    })
  end

  defp resource_metric(attributes, "system_fd_used"),
    do: get_in(attributes, ["system_fd", "used"])

  defp resource_metric(attributes, "system_fd_limit"),
    do: get_in(attributes, ["system_fd", "limit"])

  defp resource_metric(attributes, "system_fd_available"),
    do: get_in(attributes, ["system_fd", "available"])

  defp resource_metric(attributes, "system_fd_headroom_ratio"),
    do: get_in(attributes, ["system_fd", "headroom_ratio"])

  defp resource_metric(attributes, metric), do: Map.get(attributes, metric)

  defp resource_profile(samples) do
    @resource_metrics
    |> Enum.flat_map(fn metric ->
      values = samples |> Enum.map(&Map.get(&1, metric)) |> Enum.filter(&is_number/1)
      if values == [], do: [], else: [{metric, statistics(values)}]
    end)
    |> Map.new()
  end

  defp statistics(values) do
    sorted = Enum.sort(values)
    count = length(sorted)

    %{
      count: count,
      min: hd(sorted),
      mean: Enum.sum(sorted) / count,
      median: percentile(sorted, 0.5, :interpolate),
      p95: percentile(sorted, 0.95, :nearest_rank),
      max: List.last(sorted)
    }
  end

  defp percentile(sorted, percentile, :nearest_rank) do
    index = max(ceil(percentile * length(sorted)) - 1, 0)
    Enum.at(sorted, index)
  end

  defp percentile(sorted, 0.5, :interpolate) do
    count = length(sorted)
    midpoint = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, midpoint)
    else
      (Enum.at(sorted, midpoint - 1) + Enum.at(sorted, midpoint)) / 2
    end
  end

  defp resource_gaps(samples, opts) do
    interval_ms = Keyword.get(opts, :sample_interval_ms, @default_sample_interval_ms)

    threshold_ms =
      Keyword.get(
        opts,
        :sample_gap_threshold_ms,
        round(interval_ms * @default_gap_threshold_multiplier)
      )

    samples
    |> Enum.group_by(& &1.boot_id)
    |> Enum.flat_map(fn {boot_id, boot_samples} ->
      boot_samples
      |> Enum.sort_by(& &1.timestamp_ms)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(&resource_gap(&1, boot_id, interval_ms, threshold_ms))
    end)
    |> Enum.sort_by(&{&1.start_at, &1.boot_id})
  end

  defp resource_gap([previous, current], boot_id, interval_ms, threshold_ms) do
    duration_ms = current.timestamp_ms - previous.timestamp_ms

    if duration_ms > threshold_ms do
      [
        %{
          boot_id: boot_id,
          start_at: previous.timestamp,
          end_at: current.timestamp,
          duration_ms: duration_ms,
          expected_interval_ms: interval_ms
        }
      ]
    else
      []
    end
  end

  defp availability_counts(samples) do
    Enum.reduce(samples, %{measured: 0, unavailable: 0}, fn sample, counts ->
      key = if sample.availability == "measured", do: :measured, else: :unavailable
      Map.update!(counts, key, &(&1 + 1))
    end)
  end

  defp reduce_tickets(records, opts) do
    # Caller timestamps describe when an event occurred, but lifecycle pairing
    # must follow append order when a segment boundary is interleaved.
    events =
      records
      |> Enum.filter(&(&1.kind == "lifecycle"))
      |> Enum.flat_map(&lifecycle_event/1)
      |> Enum.sort_by(&lifecycle_sort_key/1)

    events_by_ticket = Enum.group_by(events, & &1.ticket)
    findings = review_findings(events_by_ticket, opts)
    findings_by_ticket = Enum.group_by(findings, & &1.ticket)

    tickets =
      Map.new(events_by_ticket, fn {ticket, ticket_events} ->
        {ticket,
         %{
           ticket: ticket,
           complexity: dispatch_complexity(ticket_events),
           events: ticket_events,
           intervals: lifecycle_intervals(ticket_events),
           findings: Map.get(findings_by_ticket, ticket, [])
         }}
      end)

    {tickets, findings}
  end

  defp lifecycle_event(record) do
    attributes = record.attributes

    with ticket when is_binary(ticket) and ticket != "" <- Map.get(attributes, "ticket"),
         event when is_binary(event) and event != "" <- Map.get(attributes, "event"),
         boundary when boundary in ["start", "end", "point"] <- Map.get(attributes, "boundary") do
      [
        %{
          ticket: ticket,
          event: event,
          boundary: boundary,
          attempt_id: Map.get(attributes, "attempt_id"),
          operation_id: Map.get(attributes, "operation_id"),
          outcome: Map.get(attributes, "outcome"),
          command_class: Map.get(attributes, "command_class"),
          cause: Map.get(attributes, "cause"),
          complexity: normalize_complexity(Map.get(attributes, "complexity")),
          source: Map.get(attributes, "source"),
          source_id: Map.get(attributes, "source_id"),
          segment_continuation: Map.get(attributes, "segment_continuation"),
          timestamp: record.timestamp_iso,
          timestamp_dt: record.timestamp,
          timestamp_ms: record.timestamp_ms,
          recorded_at_ms: recorded_at_ms(record),
          boot_id: record.boot_id,
          sequence: record.sequence,
          record_id: record.record_id,
          source_path: record.source_path,
          source_line: record.source_line
        }
      ]
    else
      _other -> []
    end
  end

  defp recorded_at_ms(%{recorded_at: recorded_at}) do
    case parse_timestamp(recorded_at) do
      {:ok, parsed} -> DateTime.to_unix(parsed, :millisecond)
      :error -> nil
    end
  end

  defp lifecycle_sort_key(event) do
    chronological_sort_key(event)
  end

  defp chronological_sort_key(event) do
    {
      event.timestamp_ms,
      event.source_path || "",
      event.source_line || 0,
      event.record_id
    }
  end

  defp normalize_complexity(value) when is_integer(value) and value in 1..5, do: value

  defp normalize_complexity(value) when is_binary(value) do
    case Integer.parse(value) do
      {value, ""} when value in 1..5 -> value
      _other -> nil
    end
  end

  defp normalize_complexity(_value), do: nil

  defp dispatch_complexity(events) do
    Enum.find_value(events, fn
      %{event: "dispatch", complexity: complexity} when is_integer(complexity) -> complexity
      _event -> nil
    end)
  end

  defp lifecycle_intervals(events) do
    events
    |> Enum.group_by(&lifecycle_pair_key/1)
    |> Enum.flat_map(fn {_key, pair_events} -> lifecycle_pair_intervals(pair_events) end)
    |> Enum.sort_by(&{&1.start_ms, &1.phase, &1.operation_id || ""})
  end

  defp lifecycle_pair_intervals(events) do
    {intervals, open} =
      events
      |> causal_pair_order()
      |> Enum.reduce({[], %{}}, fn event, {intervals, open} ->
        key = lifecycle_pair_key(event)

        case event.boundary do
          "start" ->
            {intervals, retain_lifecycle_start(open, key, event)}

          "end" ->
            close_lifecycle_interval(event, intervals, open, key)

          "point" ->
            {[point_interval(event, "point") | intervals], open}
        end
      end)

    intervals ++ Enum.map(open, fn {_key, event} -> open_interval(event) end)
  end

  # Lifecycle pairing depends on seeing a start before its matching finish, and
  # timestamps alone cannot guarantee that: a segment roll can emit two records
  # inside the same clock millisecond, so a purely chronological sort is free to
  # invert a causally ordered pair and manufacture an `orphan_end`.
  #
  # When every event came from one persisted stream, append order is the ground
  # truth and `source_line` reproduces it exactly, so sort by that instead.
  # `record_id` only breaks ties within a line. Across several streams — or when
  # any line number is missing, as with in-memory events — no shared append order
  # exists, so fall back to the chronological key.
  defp causal_pair_order(events) do
    same_persisted_stream? =
      events
      |> Enum.map(& &1.source_path)
      |> Enum.uniq()
      |> then(fn paths ->
        length(paths) == 1 and is_binary(hd(paths)) and
          Enum.all?(events, &is_integer(&1.source_line))
      end)

    if same_persisted_stream? do
      Enum.sort_by(events, &{&1.source_line, &1.record_id})
    else
      Enum.sort_by(events, &chronological_sort_key/1)
    end
  end

  defp close_lifecycle_interval(event, intervals, open, key) do
    if event.segment_continuation == "close" do
      {intervals, open}
    else
      case Map.pop(open, key) do
        {nil, next_open} -> {[point_interval(event, "orphan_end") | intervals], next_open}
        {started, next_open} -> {[closed_interval(started, event) | intervals], next_open}
      end
    end
  end

  defp retain_lifecycle_start(open, key, %{segment_continuation: "open"})
       when is_map_key(open, key), do: open

  defp retain_lifecycle_start(open, key, event), do: Map.put(open, key, event)

  defp lifecycle_pair_key(event),
    do: {event.attempt_id, event.event, event.operation_id}

  defp closed_interval(started, finished) do
    {end_at, end_ms} = causal_endpoints(started, finished)

    interval_base(started)
    |> Map.merge(%{
      status: "closed",
      end_at: end_at,
      end_ms: end_ms,
      duration_ms: end_ms - started.timestamp_ms,
      outcome: finished.outcome || started.outcome
    })
  end

  defp causal_endpoints(started, finished) do
    if finished.timestamp_ms < started.timestamp_ms do
      {started.timestamp, started.timestamp_ms}
    else
      {finished.timestamp, finished.timestamp_ms}
    end
  end

  defp point_interval(event, status) do
    interval_base(event)
    |> Map.merge(%{
      status: status,
      end_at: nil,
      end_ms: nil,
      duration_ms: nil,
      outcome: event.outcome
    })
  end

  defp open_interval(event) do
    interval_base(event)
    |> Map.merge(%{
      status: "open",
      end_at: nil,
      end_ms: nil,
      duration_ms: nil,
      outcome: event.outcome
    })
  end

  defp interval_base(event) do
    %{
      ticket: event.ticket,
      phase: event.event,
      attempt_id: event.attempt_id,
      operation_id: event.operation_id,
      command_class: event.command_class,
      complexity: event.complexity,
      cause: event.cause,
      source_id: event.source_id,
      start_at: event.timestamp,
      start_ms: event.timestamp_ms
    }
  end

  defp review_findings(events_by_ticket, opts) do
    grace_seconds =
      Keyword.get(
        opts,
        :review_resume_grace_seconds,
        @default_review_resume_grace_seconds
      )

    now = Keyword.get(opts, :now, DateTime.utc_now())

    events_by_ticket
    |> Enum.flat_map(fn {ticket, events} ->
      events
      |> Enum.filter(&(&1.event == "comment_received"))
      |> Enum.flat_map(&review_finding(ticket, events, &1, now, grace_seconds))
    end)
    |> Enum.sort_by(&{&1.comment_at, &1.ticket})
  end

  defp review_finding(ticket, events, comment, now, grace_seconds) do
    case active_review_pause(events, comment) do
      nil ->
        []

      review_pause ->
        {window, closing_event} = response_window(events, comment)
        rework_index = Enum.find_index(window, &(&1.event == "rework_start"))

        resume_after_rework? =
          is_integer(rework_index) and
            window
            |> Enum.drop(rework_index + 1)
            |> Enum.any?(&(&1.event == "agent_resume"))

        rework? = is_integer(rework_index)
        terminal? = match?(%{event: "pr_merged"}, closing_event)
        missing = missing_response_events(rework?, resume_after_rework?)
        deadline = DateTime.add(comment.timestamp_dt, grace_seconds, :second)

        status =
          cond do
            missing == [] -> "resolved"
            terminal? -> "closed"
            DateTime.compare(now, deadline) == :lt -> "pending"
            true -> "broken"
          end

        [
          %{
            type: "review_pause_resume",
            ticket: ticket,
            status: status,
            review_pause_at: review_pause.timestamp,
            comment_at: comment.timestamp,
            comment_source_id: comment.source_id,
            grace_deadline: DateTime.to_iso8601(deadline),
            missing: missing
          }
        ]
    end
  end

  defp active_review_pause(events, comment) do
    events
    |> Enum.take_while(&(&1.timestamp_ms < comment.timestamp_ms))
    |> Enum.reverse()
    |> Enum.take_while(&(&1.event not in ["pr_merged", "agent_resume"]))
    |> Enum.find(&(&1.event == "review_pause"))
  end

  defp response_window(events, comment) do
    events
    |> Enum.drop_while(&(&1.timestamp_ms <= comment.timestamp_ms))
    |> Enum.reduce_while({[], nil}, fn event, {window, _closing_event} ->
      if event.event in ["review_pause", "pr_merged"] do
        {:halt, {Enum.reverse(window), event}}
      else
        {:cont, {[event | window], nil}}
      end
    end)
    |> then(fn
      {window, nil} -> {Enum.reverse(window), nil}
      result -> result
    end)
  end

  defp missing_response_events(rework?, resume?) do
    []
    |> maybe_missing(not rework?, "rework_start")
    |> maybe_missing(not resume?, "agent_resume")
  end

  defp maybe_missing(missing, true, event), do: missing ++ [event]
  defp maybe_missing(missing, false, _event), do: missing

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

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value) when is_boolean(value) or is_nil(value), do: value
  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_keys(value), do: value

  defp warning(type, path, line_number, extra \\ %{}) do
    Map.merge(extra, %{type: type, path: path, line: line_number})
  end

  defp exception_class(%{__struct__: module}),
    do: module |> Module.split() |> List.last() |> Macro.underscore()
end
