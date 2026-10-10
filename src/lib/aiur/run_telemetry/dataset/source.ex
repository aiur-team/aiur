defmodule Aiur.RunTelemetry.Dataset.Source do
  @moduledoc "Telemetry file discovery, bounded tail reads, and record parsing/normalization for `Aiur.RunTelemetry.Dataset`."

  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.Lifecycle

  @telemetry_filename "telemetry.ndjson"
  @supported_kinds ~w(restart lifecycle resource warning)
  @tail_chunk_bytes 64 * 1024
  @max_tail_line_bytes 1 * 1024 * 1024

  @doc false
  @spec discover_files([Path.t()]) :: [Path.t()]
  def discover_files(inputs) do
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

  @doc false
  @spec read_files([Path.t()], keyword()) :: {[map()], [map()]}
  def read_files(files, opts) do
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

  @doc false
  @spec parse_timestamp(term()) :: {:ok, DateTime.t()} | :error
  def parse_timestamp(%DateTime{} = timestamp), do: {:ok, timestamp}

  def parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      _other -> :error
    end
  end

  def parse_timestamp(_timestamp), do: :error

  @doc false
  @spec github_records(term()) :: {[map()], [map()]}
  def github_records(events) when is_list(events) do
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

  def github_records(_events), do: {[], [%{type: :invalid_github_events}]}

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
