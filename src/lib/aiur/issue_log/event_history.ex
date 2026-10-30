defmodule Aiur.IssueLog.EventHistory do
  @moduledoc false

  alias Aiur.IssueLog.Encoding

  @max_tail_page_events 50
  @max_tail_bytes (Encoding.max_record_bytes() + 1) * @max_tail_page_events

  @spec max_tail_bytes() :: pos_integer()
  def max_tail_bytes, do: @max_tail_bytes

  @spec read_event_history(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def read_event_history(path, opts) do
    since_id = Keyword.get(opts, :since_id, 0)
    kinds = Keyword.get(opts, :kinds, [:emit, :emit_alert])
    limit = Keyword.fetch!(opts, :limit)
    kind_set = MapSet.new(Enum.map(kinds, &Atom.to_string/1))

    case File.read(path) do
      {:ok, content} ->
        events =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_event_line/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.filter(fn ev ->
            MapSet.member?(kind_set, ev.kind) and is_integer(ev.id) and ev.id > since_id
          end)
          |> Enum.take(-limit)

        {:ok, events}

      {:error, :enoent} ->
        {:error, :missing_source}

      {:error, reason} ->
        {:error, {:unavailable, reason}}
    end
  end

  @spec read_event_page(String.t(), keyword()) :: {:ok, %{events: [map()], high_water: non_neg_integer(), has_more: boolean()}} | {:error, term()}
  def read_event_page(path, opts) do
    after_id = Keyword.get(opts, :after_id, 0)
    limit = Keyword.get(opts, :limit, 200)
    kinds = opts |> Keyword.get(:kinds, [:emit, :emit_alert, :consumed, :self, :command]) |> Enum.map(&Atom.to_string/1) |> MapSet.new()

    with true <- is_integer(after_id) and after_id >= 0 and is_integer(limit) and limit in 1..500,
         {:ok, %{size: size}} <- File.stat(path, time: :posix),
         {:ok, content} <- read_page_chunk(path, page_start(size, after_id, limit), page_bytes(size, after_id, limit)) do
      events =
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_event_line/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&(MapSet.member?(kinds, &1.kind) and &1.id > after_id))
        |> Enum.sort_by(& &1.id)

      page = Enum.take(events, limit)
      {:ok, %{events: page, high_water: Enum.reduce(page, after_id, &max(&2, &1.id)), has_more: length(events) > limit}}
    else
      false -> {:error, :invalid_page}
      {:error, :enoent} -> {:ok, %{events: [], high_water: after_id, has_more: false}}
      {:error, reason} -> {:error, {:unavailable, reason}}
    end
  end

  defp page_start(_size, 0, _limit), do: 0
  defp page_start(size, _after_id, limit), do: max(size - (Encoding.max_record_bytes() + 1) * limit * 2, 0)

  defp page_bytes(size, 0, _limit), do: size
  defp page_bytes(size, _after_id, limit), do: min(size, (Encoding.max_record_bytes() + 1) * limit * 2)

  defp read_page_chunk(path, start, bytes) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        case :file.pread(file, start, bytes) do
          {:ok, content} when start > 0 ->
            case :binary.match(content, "\n") do
              {index, 1} -> {:ok, binary_part(content, index + 1, byte_size(content) - index - 1)}
              :nomatch -> {:ok, ""}
            end

          result ->
            result
        end
      after
        :ok = File.close(file)
      end
    end
  end

  defp parse_event_line(line) do
    # Matches the optional `src=…` / `trust=…` / `digest=…` flag segments between
    # `id=…` and the topic. Flags are surfaced as fields on the parsed
    # event so bootstrap replays carry the same `author_trusted?` +
    # `source` signal that the render-side filter and `<external-content>`
    # wrapper depend on (a missing flag is treated as untrusted /
    # non-github respectively).
    case Regex.run(
           ~r/\A([0-9T:\-\.Z]+) \[event:([a-z_]+)\] id=(\d+)((?: \w+=[^\s]+)*) ([^:\s]+)(?:: (.*))?\z/,
           line
         ) do
      [_, ts, kind, id_str, flag_segment, topic, summary] ->
        build_parsed_event(ts, kind, id_str, flag_segment, topic, summary)

      [_, ts, kind, id_str, flag_segment, topic] ->
        build_parsed_event(ts, kind, id_str, flag_segment, topic, "")

      _ ->
        nil
    end
  end

  defp build_parsed_event(ts, kind, id_str, flag_segment, topic, summary) do
    flags = parse_flags(flag_segment)
    summary = if kind == "command", do: decode_command(flags, summary), else: summary

    %{
      kind: kind,
      id: String.to_integer(id_str),
      topic: topic,
      ts: ts,
      summary: summary,
      source: flags |> Map.get("src") |> maybe_atomize_source(),
      author_trusted?: flags |> Map.get("trust") |> maybe_atomize_bool(),
      digest_source: flags |> Map.get("digest") |> maybe_atomize_digest_source(),
      actor: Map.get(flags, "actor"),
      percent: safe_percent(Map.get(flags, "pct")),
      ci_checks: safe_ci_checks(Map.get(flags, "ci")),
      review_state: safe_review_state(Map.get(flags, "review"))
    }
  end

  defp decode_command(%{"cmd" => encoded}, _summary) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, command} -> command
      :error -> ""
    end
  end

  defp decode_command(_flags, summary), do: summary

  defp safe_percent(value) when is_binary(value) do
    case Integer.parse(value) do
      {percent, ""} when percent in 0..100 -> percent
      _ -> nil
    end
  end

  defp safe_percent(_value), do: nil

  defp safe_ci_checks(encoded) when is_binary(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, checks} when is_list(checks) <- Jason.decode(json) do
      Enum.take(checks, 30)
      |> Enum.flat_map(fn
        %{"name" => name, "url" => url} when is_binary(name) and is_binary(url) -> [%{name: name, url: url}]
        %{"name" => name, "url" => nil} when is_binary(name) -> [%{name: name}]
        %{"name" => name} when is_binary(name) -> [%{name: name}]
        _ -> []
      end)
    else
      _ -> []
    end
  end

  defp safe_ci_checks(_value), do: []

  defp safe_review_state(value) when value in ["APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED", "PENDING"], do: value
  defp safe_review_state(_value), do: nil

  defp parse_flags(flag_segment) when is_binary(flag_segment) do
    flag_segment
    |> String.split(" ", trim: true)
    |> Enum.flat_map(fn token ->
      case String.split(token, "=", parts: 2) do
        [k, v] -> [{k, v}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp parse_flags(_), do: %{}

  defp maybe_atomize_source(nil), do: nil
  defp maybe_atomize_source("github"), do: :github
  defp maybe_atomize_source(other) when is_binary(other), do: other
  defp maybe_atomize_source(_), do: nil

  defp maybe_atomize_bool(nil), do: nil
  defp maybe_atomize_bool("true"), do: true
  defp maybe_atomize_bool("false"), do: false
  defp maybe_atomize_bool(_), do: nil

  # `digest=` is written only by IssueLog from Publisher's reserved envelope
  # field. Rehydrate its fixed vocabulary to atoms so EventsDigest never
  # treats an arbitrary string from an unknown event source as trusted.
  defp maybe_atomize_digest_source("agent"), do: :agent
  defp maybe_atomize_digest_source("orchestrator"), do: :orchestrator
  defp maybe_atomize_digest_source("system"), do: :system
  defp maybe_atomize_digest_source(_), do: nil

  @spec parse_line(String.t()) :: map() | nil
  def parse_line(line) do
    case Regex.run(~r/\A([0-9T:\-\.Z]+) \[([a-z]+)\] (.*)\z/, line) do
      [_, _ts, tag, body] ->
        case role_from_tag(tag) do
          nil -> nil
          role -> %{role: role, body: body, turn_id: nil}
        end

      _ ->
        nil
    end
  end

  defp role_from_tag("agent"), do: :assistant
  defp role_from_tag("user"), do: :user
  defp role_from_tag("cmd"), do: :command
  defp role_from_tag("system"), do: :system
  defp role_from_tag("alert"), do: :alert
  defp role_from_tag(_), do: nil

  @spec read_tail_chunk(String.t(), non_neg_integer(), non_neg_integer()) :: {:ok, binary()} | :eof | {:error, term()}
  def read_tail_chunk(path, start_offset, byte_count) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        :file.pread(file, start_offset, byte_count)
      after
        :ok = File.close(file)
      end
    end
  end

  @spec tail_chunk_bytes(pos_integer()) :: pos_integer()
  def tail_chunk_bytes(limit), do: min(limit * (Encoding.max_record_bytes() + 1), @max_tail_bytes)

  @spec parse_tail_cursor(term()) :: {:ok, non_neg_integer() | nil} | {:error, :invalid_cursor}
  def parse_tail_cursor(nil), do: {:ok, nil}
  def parse_tail_cursor(cursor) when is_integer(cursor) and cursor >= 0, do: {:ok, cursor}

  def parse_tail_cursor(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {value, ""} when value >= 0 -> {:ok, value}
      _ -> {:error, :invalid_cursor}
    end
  end

  def parse_tail_cursor(_), do: {:error, :invalid_cursor}

  @spec tail_page(binary(), non_neg_integer(), pos_integer()) :: %{events: [map()], next_cursor: String.t() | nil}
  def tail_page(bytes, start_offset, limit) do
    {first, rest} = split_tail_lines(bytes, start_offset)

    events =
      rest
      |> line_offsets(first)
      |> Enum.flat_map(fn {line, offset} ->
        case Jason.decode(line) do
          {:ok, %{} = event} -> [{event, offset}]
          _ -> []
        end
      end)
      |> Enum.reverse()
      |> Enum.take(limit)

    next_cursor =
      case List.last(events) do
        {_event, 0} -> nil
        {_event, offset} -> Integer.to_string(offset)
        nil -> if(start_offset > 0, do: Integer.to_string(start_offset), else: nil)
      end

    %{events: Enum.map(events, &elem(&1, 0)), next_cursor: next_cursor}
  end

  # The first line in a nonzero byte slice may begin in the middle of a JSON
  # document, so discard it. Keep its byte length so offsets stay absolute.
  defp split_tail_lines(bytes, 0), do: {0, String.split(bytes, "\n", trim: true)}

  defp split_tail_lines(bytes, start_offset) do
    case String.split(bytes, "\n", parts: 2) do
      [_partial, rest] -> {start_offset + byte_size(bytes) - byte_size(rest), String.split(rest, "\n", trim: true)}
      [_partial] -> {start_offset + byte_size(bytes), []}
    end
  end

  defp line_offsets(lines, initial_offset) do
    {records, _offset} =
      Enum.map_reduce(lines, initial_offset, fn line, offset ->
        {{line, offset}, offset + byte_size(line) + 1}
      end)

    records
  end
end
