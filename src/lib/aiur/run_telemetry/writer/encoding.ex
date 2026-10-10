defmodule Aiur.RunTelemetry.Writer.Encoding do
  @moduledoc "Normalizes, timestamps, and encodes telemetry records and tracks lifecycle state for `Aiur.RunTelemetry.Writer`."

  alias Aiur.RunTelemetry

  # Point events that define a ticket's completion for the run-scoped
  # analytics. A segment roll prunes every earlier segment of the live boot, so
  # these are re-emitted after each boundary (marked `segment_continuation:
  # "carried"`) or the boot would forget a merge it already observed (#2603).
  @carried_point_events ~w(dispatch pr_opened pr_merged)

  defp next_sequence(%{shared_sequence?: true}), do: RunTelemetry.next_sequence()
  defp next_sequence(state), do: state.sequence + 1

  defp maybe_mark_writer_restart(%{shared_sequence?: true}, kind, attributes, sequence)
       when kind in [:restart, "restart"] and sequence > 1 do
    if Map.get(attributes, :event) in [:daemon_restart, "daemon_restart"] do
      Map.put(attributes, :event, :telemetry_writer_restart)
    else
      attributes
    end
  end

  defp maybe_mark_writer_restart(_state, _kind, attributes, _sequence), do: attributes

  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: kind
  defp normalize_kind(kind), do: inspect(kind)

  defp normalize_timestamp(kind, timestamp, fallback) when kind in [:lifecycle, "lifecycle"] do
    normalize_lifecycle_timestamp(timestamp, fallback)
  end

  defp normalize_timestamp(_kind, timestamp, _fallback), do: normalize_timestamp(timestamp)

  defp normalize_lifecycle_timestamp(%DateTime{} = timestamp, _fallback), do: DateTime.to_iso8601(timestamp)

  defp normalize_lifecycle_timestamp(timestamp, fallback) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> DateTime.to_iso8601(parsed)
      _other -> DateTime.to_iso8601(fallback)
    end
  end

  defp normalize_lifecycle_timestamp(_timestamp, fallback), do: DateTime.to_iso8601(fallback)

  defp normalize_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp normalize_timestamp(timestamp) when is_binary(timestamp), do: timestamp
  defp normalize_timestamp(_timestamp), do: DateTime.utc_now() |> DateTime.to_iso8601()

  @doc false
  @spec clock_timestamp((-> term())) :: DateTime.t()
  def clock_timestamp(clock) do
    clock.() |> validate_clock_timestamp()
  end

  defp validate_clock_timestamp(timestamp) do
    case timestamp do
      %DateTime{} = timestamp ->
        timestamp

      timestamp when is_binary(timestamp) ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, parsed, _offset} -> parsed
          _other -> DateTime.utc_now()
        end

      _other ->
        DateTime.utc_now()
    end
  end

  @doc false
  @spec encode_records(map(), [tuple()]) :: {map(), binary(), [tuple()]}
  def encode_records(state, records) do
    {state, lines, encoded_records} =
      Enum.reduce(records, {state, [], []}, fn {kind, attributes, timestamp}, {state, lines, encoded_records} ->
        sequence = next_sequence(state)
        attributes = maybe_mark_writer_restart(state, kind, attributes, sequence)
        recorded_at = clock_timestamp(state.clock)
        normalized_timestamp = normalize_timestamp(kind, timestamp, recorded_at)

        envelope = %{
          schema_version: RunTelemetry.schema_version(),
          kind: normalize_kind(kind),
          timestamp: normalized_timestamp,
          recorded_at: DateTime.to_iso8601(recorded_at),
          boot_id: state.boot_id,
          sequence: sequence,
          record_id: "#{state.boot_id}:#{sequence}",
          attributes: attributes
        }

        {:ok, encoded} = Jason.encode(Aiur.JSONSafe.normalize(envelope))

        {
          %{state | sequence: sequence},
          [[encoded, "\n"] | lines],
          [{kind, attributes, normalized_timestamp} | encoded_records]
        }
      end)

    {state, lines |> Enum.reverse() |> IO.iodata_to_binary(), Enum.reverse(encoded_records)}
  end

  @doc false
  @spec track_lifecycles(map(), [tuple()]) :: map()
  def track_lifecycles(open_lifecycles, records) do
    Enum.reduce(records, open_lifecycles, fn {kind, attributes, timestamp}, open_lifecycles ->
      case lifecycle_key(kind, attributes) do
        {:start, key} -> Map.put(open_lifecycles, key, {attributes, timestamp})
        {:end, key} -> Map.delete(open_lifecycles, key)
        :skip -> open_lifecycles
      end
    end)
  end

  # Remembers each terminal ticket point once per identity (`event_key`), with
  # its original timestamp, so a carried replica lands on the burn-up axis where
  # the merge actually happened. A replica re-tracks to the same key, so the set
  # stays bounded by the tickets this boot touched.
  @doc false
  @spec track_carried_points(map(), [tuple()]) :: map()
  def track_carried_points(carried_points, records) do
    Enum.reduce(records, carried_points, fn {kind, attributes, timestamp}, carried_points ->
      case carried_point_key(kind, attributes) do
        {:ok, key} -> Map.put_new(carried_points, key, {attributes, timestamp})
        :skip -> carried_points
      end
    end)
  end

  defp carried_point_key(kind, attributes) when kind in [:lifecycle, "lifecycle"] and is_map(attributes) do
    event = attributes |> attribute_value(:event) |> to_string()
    boundary = attributes |> attribute_value(:boundary) |> to_string()
    event_key = attribute_value(attributes, :event_key)

    if event in @carried_point_events and boundary == "point" and is_binary(event_key),
      do: {:ok, event_key},
      else: :skip
  end

  defp carried_point_key(_kind, _attributes), do: :skip

  @doc false
  @spec carried_point_records(map()) :: [tuple()]
  def carried_point_records(carried_points) do
    carried_points
    |> Enum.sort_by(fn {_key, {_attributes, timestamp}} -> to_string(timestamp) end)
    |> Enum.map(fn {_key, {attributes, timestamp}} ->
      {:lifecycle, put_attribute(attributes, :segment_continuation, "carried"), timestamp}
    end)
  end

  @doc false
  @spec segment_lifecycle_records(map(), DateTime.t()) :: {[tuple()], [tuple()], map()}
  def segment_lifecycle_records(open_lifecycles, timestamp) do
    open_lifecycles
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.reduce({[], [], %{}}, fn {key, {attributes, started_at}}, {closing, reopening, continued} ->
      timestamp = causal_timestamp(timestamp, started_at)

      closing_attributes =
        attributes
        |> put_attribute(:boundary, "end")
        |> put_attribute(:duration_status, "segmented")
        |> put_attribute(:segment_continuation, "close")

      opening_attributes =
        attributes
        |> put_attribute(:boundary, "start")
        |> put_attribute(:duration_status, "segmented")
        |> put_attribute(:segment_continuation, "open")

      {
        [{:lifecycle, closing_attributes, timestamp} | closing],
        [{:lifecycle, opening_attributes, timestamp} | reopening],
        Map.put(continued, key, {opening_attributes, timestamp})
      }
    end)
    |> then(fn {closing, reopening, continued} -> {Enum.reverse(closing), Enum.reverse(reopening), continued} end)
  end

  defp causal_timestamp(timestamp, started_at) do
    timestamp = validate_clock_timestamp(timestamp)

    case validate_lifecycle_timestamp(started_at) do
      {:ok, started_at} ->
        if DateTime.compare(timestamp, started_at) == :lt, do: started_at, else: timestamp

      _other ->
        timestamp
    end
  end

  defp validate_lifecycle_timestamp(%DateTime{} = timestamp), do: {:ok, timestamp}

  defp validate_lifecycle_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      _other -> :error
    end
  end

  defp validate_lifecycle_timestamp(_timestamp), do: :error

  defp lifecycle_key(kind, attributes) when kind in [:lifecycle, "lifecycle"] and is_map(attributes) do
    case attribute_value(attributes, :boundary) do
      boundary when boundary in [:start, "start"] -> {:start, lifecycle_pair_key(attributes)}
      boundary when boundary in [:end, "end"] -> {:end, lifecycle_pair_key(attributes)}
      _other -> :skip
    end
  end

  defp lifecycle_key(_kind, _attributes), do: :skip

  defp lifecycle_pair_key(attributes) do
    {
      attribute_value(attributes, :attempt_id),
      attribute_value(attributes, :event),
      attribute_value(attributes, :operation_id)
    }
  end

  defp attribute_value(attributes, key), do: Map.get(attributes, key) || Map.get(attributes, Atom.to_string(key))

  defp put_attribute(attributes, key, value) do
    attributes
    |> Map.delete(Atom.to_string(key))
    |> Map.put(key, value)
  end
end
