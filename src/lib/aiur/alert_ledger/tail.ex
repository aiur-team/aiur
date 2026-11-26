defmodule Aiur.AlertLedger.Tail do
  @moduledoc false

  alias Aiur.Jsonl

  @key {__MODULE__, :tails}

  @spec read(Path.t(), pos_integer()) :: [map()]
  def read(path, max_bytes) when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, device} ->
        try do
          read_device(device, path, max_bytes)
        after
          :file.close(device)
        end

      {:error, _reason} ->
        forget(path)
        []
    end
  end

  defp read_device(device, path, max_bytes) do
    with {:ok, info} <- :file.read_file_info(device),
         stat = File.Stat.from_record(info),
         {:ok, size} <- :file.position(device, :eof) do
      identity = {stat.major_device, stat.minor_device, stat.inode, max_bytes}
      tails = Process.get(@key, %{})
      previous = Map.get(tails, path)
      start = max(size - max_bytes, 0)
      state = reusable(previous, identity, stat, size)
      state = if state && state.offset >= start, do: state, else: cold(device, start, size)
      {:ok, _offset} = :file.position(device, state.offset)
      {:ok, contents} = read_bytes(device, size - state.offset)
      {entries, offset} = decode(contents, state.offset, state.entries)
      entries = Enum.filter(entries, fn {at, _record} -> start == 0 or at > start end)
      cached = %{identity: identity, size: size, mtime: stat.mtime, ctime: stat.ctime, offset: offset, entries: entries}
      Process.put(@key, Map.put(if(map_size(tails) < 8 or Map.has_key?(tails, path), do: tails, else: %{}), path, cached))
      records(entries) ++ partial(contents, size - state.offset, offset - state.offset, start == 0 or offset > start)
    else
      _ ->
        forget(path)
        []
    end
  end

  defp reusable(%{identity: identity, size: size} = state, identity, stat, size) do
    if state.mtime == stat.mtime and state.ctime == stat.ctime, do: state
  end

  defp reusable(%{identity: identity, size: previous} = state, identity, _stat, size) when size > previous, do: state
  defp reusable(_state, _identity, _stat, _size), do: nil

  defp cold(_device, 0, _size), do: %{offset: 0, entries: []}

  defp cold(device, start, size) do
    # Read at most the bounded tail; a leading fragment must never become a record.
    {:ok, ^start} = :file.position(device, start)
    {:ok, contents} = :file.read(device, size - start)

    offset =
      case :binary.match(contents, "\n") do
        {index, 1} -> start + index + 1
        :nomatch -> start + byte_size(contents)
      end

    %{offset: offset, entries: []}
  end

  defp decode(contents, offset, entries) do
    lines = :binary.split(contents, "\n", [:global])
    complete = Enum.drop(lines, -1)

    {new, offset} =
      Enum.map_reduce(complete, offset, fn line, at ->
        record =
          case Jsonl.decode_line(line) do
            {:ok, record} -> {at, record}
            :skip -> nil
          end

        {record, at + byte_size(line) + 1}
      end)

    {entries ++ Enum.reject(new, &is_nil/1), offset}
  end

  defp partial(contents, size, consumed, true) when consumed < size do
    case Jsonl.decode_line(binary_part(contents, consumed, size - consumed)) do
      {:ok, record} -> [record]
      :skip -> []
    end
  end

  defp partial(_contents, _size, _consumed, _visible), do: []
  defp records(entries), do: Enum.map(entries, &elem(&1, 1))
  defp read_bytes(_device, 0), do: {:ok, ""}
  defp read_bytes(device, bytes), do: :file.read(device, bytes)
  defp forget(path), do: Process.put(@key, Map.delete(Process.get(@key, %{}), path))
end
