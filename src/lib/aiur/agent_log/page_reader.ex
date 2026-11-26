defmodule Aiur.AgentLog.PageReader do
  @moduledoc "Bounded, byte-cursor pagination of structured agent transcripts."
  alias Aiur.AgentLog
  alias Aiur.AgentLog.PageReader.Scanner
  @budget 1_048_576
  @extension 4 * @budget

  @spec tail(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def tail(path, opts \\ []), do: read(path, :tail, nil, opts)
  @spec before(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def before(path, cursor, opts \\ []), do: read(path, :before, cursor, opts)
  @spec since(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def since(path, cursor, opts \\ []), do: read(path, :since, cursor, opts)

  defp read(path, mode, cursor, opts) do
    with {:ok, fd} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        read_open(fd, mode, cursor, opts)
      after
        :file.close(fd)
      end
    end
  end

  defp read_open(fd, mode, cursor, opts) do
    pread = Keyword.get(opts, :pread, &:file.pread/3)

    with {:ok, stat} <- :file.read_file_info(fd),
         {:ok, prefix} <- prefix(fd, pread),
         size = elem(stat, 1),
         gen = Integer.to_string(:erlang.phash2({elem(stat, 9), elem(stat, 11), prefix}), 16),
         {:ok, offset} <- validate(fd, cursor, gen, size, mode, pread) do
      direction = if mode == :since, do: :forward, else: :backward
      scan = Scanner.new(fd, direction, offset, size, pread)

      with {:ok, scan} <- prepare(scan, mode) do
        limit = opts |> Keyword.get(:limit, 100) |> max(1) |> min(500)
        collect(scan, [], gen, limit, nil)
      end
    end
  end

  defp prefix(fd, pread) do
    case pread.(fd, 0, 256) do
      :eof -> {:ok, ""}
      result -> result
    end
  end

  defp validate(_fd, nil, _gen, size, :tail, _pread), do: {:ok, size}

  defp validate(fd, cursor, gen, size, _mode, pread) do
    with true <- is_binary(cursor),
         [_, token, digits] <- Regex.run(~r/\A([0-9a-fA-F]+):([0-9]+)\z/, cursor),
         {offset, ""} <- Integer.parse(digits) do
      cond do
        token != gen or offset > size -> {:error, :reset}
        offset == 0 -> {:ok, offset}
        pread.(fd, offset - 1, 1) == {:ok, "\n"} -> {:ok, offset}
        true -> {:error, :invalid_cursor}
      end
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp prepare(scan, mode) when mode != :tail, do: {:ok, scan}

  defp prepare(scan, :tail) do
    case Scanner.next(scan) do
      {:ok, _partial, offset, next} -> {:ok, %{next | finish: offset}}
      {:eof, next} -> {:ok, next}
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect(scan, entries, gen, limit, extension_start) do
    if stop?(scan, entries, limit, extension_start) do
      page(entries, scan, gen)
    else
      collect_next(Scanner.next(scan), entries, gen, limit, extension_start)
    end
  end

  defp collect_next({:eof, scan}, entries, gen, _limit, _extension), do: page(entries, scan, gen)
  defp collect_next({:error, reason}, _entries, _gen, _limit, _extension), do: {:error, reason}

  defp collect_next({:ok, line, offset, scan}, entries, gen, limit, extension) do
    message = parse(line, gen, offset)

    if extension && message && message[:merge_key] != hd(entries)[:merge_key] do
      page(entries, scan, gen, true)
    else
      entries = add(entries, message, scan.direction)
      extension = extension || extension_start(scan, entries, limit)
      collect(scan, entries, gen, limit, extension)
    end
  end

  defp extension_start(%{direction: :backward} = scan, [first | _] = entries, limit) do
    if (length(entries) >= limit or scan.bytes >= @budget) and first[:merge_key], do: scan.bytes
  end

  defp extension_start(_scan, _entries, _limit), do: nil

  defp stop?(scan, entries, limit, extension) do
    cond do
      extension -> scan.bytes - extension >= @extension
      scan.direction == :backward and entries != [] and hd(entries)[:merge_key] -> false
      true -> length(entries) >= limit or scan.bytes >= @budget
    end
  end

  defp parse(:oversized, gen, offset), do: %{id: "#{gen}:#{offset}", role: "system", title: "Entry too large to show", timestamp: "n/a", body: "Entry too large to show"}

  defp parse(line, gen, offset) do
    case AgentLog.structured_entry(line) do
      nil -> nil
      message -> Map.put(message, :id, "#{gen}:#{offset}")
    end
  end

  defp add(entries, nil, _direction), do: entries
  defp add([], message, _direction), do: [message]

  defp add([head | rest] = entries, message, direction) do
    if message[:merge_key] && message[:merge_key] == head[:merge_key] do
      {earlier, later} = if direction == :backward, do: {message, head}, else: {head, message}
      body = if later[:replace_merge?], do: later.body, else: part(earlier.body) <> part(later.body)

      [
        earlier
        |> Map.put(:body, body)
        |> Map.put(:replace_merge?, earlier[:replace_merge?] || later[:replace_merge?])
        |> Map.put(:open_merge?, Map.get(later, :open_merge?, !later[:replace_merge?]))
        |> Map.put(:timestamp, later.timestamp)
        | rest
      ]
    else
      [message | entries]
    end
  end

  defp part("No content."), do: ""
  defp part(body), do: body

  defp page(entries, scan, gen, more \\ nil) do
    entries = if scan.direction == :forward, do: Enum.reverse(entries), else: entries

    first =
      case entries do
        [entry | _] -> entry.id
        [] -> if Scanner.remaining?(scan), do: "#{gen}:#{scan.start}", else: nil
      end

    last = last_cursor(entries, scan, gen)
    {:ok, %{entries: entries, first: first, last: last, more?: if(is_nil(more), do: Scanner.remaining?(scan), else: more), gen: gen}}
  end

  defp last_cursor(entries, scan, gen) do
    final = List.last(entries)
    open_group? = final && final[:merge_key] && Map.get(final, :open_merge?, !final[:replace_merge?])
    resend? = open_group? && (scan.direction == :backward or !Scanner.remaining?(scan))

    cond do
      resend? -> final.id
      scan.direction == :backward -> "#{gen}:#{scan.finish}"
      true -> "#{gen}:#{scan.start}"
    end
  end
end
