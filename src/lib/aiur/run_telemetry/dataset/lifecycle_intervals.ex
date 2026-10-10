defmodule Aiur.RunTelemetry.Dataset.LifecycleIntervals do
  @moduledoc "Ticket lifecycle interval pairing and review wakeup findings for `Aiur.RunTelemetry.Dataset`."

  alias Aiur.RunTelemetry.Dataset.Source

  @default_review_resume_grace_seconds 300

  @doc false
  @spec reduce_tickets([map()], keyword()) :: {map(), [map()]}
  def reduce_tickets(records, opts) do
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
    case Source.parse_timestamp(recorded_at) do
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

  @doc false
  @spec lifecycle_intervals([map()]) :: [map()]
  def lifecycle_intervals(events) do
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
end
