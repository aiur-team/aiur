defmodule Aiur.AlertLedger.Tail do
  @moduledoc false

  alias Aiur.Jsonl

  @spec read(Path.t(), pos_integer()) :: [map()]
  def read(path, max_bytes) when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, device} -> read_device(device, max_bytes)
      {:error, _reason} -> []
    end
  rescue
    _ -> []
  end

  defp read_device(device, max_bytes) do
    read_tail(device, max_bytes)
  after
    :file.close(device)
  end

  defp read_tail(device, max_bytes) do
    with {:ok, size} <- :file.position(device, :eof),
         offset = max(size - max_bytes, 0),
         {:ok, ^offset} <- :file.position(device, offset),
         {:ok, contents} <- read_bytes(device, size - offset) do
      contents
      |> drop_partial_prefix(offset > 0)
      |> decode_lines()
    else
      _ -> []
    end
  end

  defp read_bytes(_device, 0), do: {:ok, ""}

  defp read_bytes(device, bytes) do
    case :file.read(device, bytes) do
      {:ok, contents} -> {:ok, contents}
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop_partial_prefix(contents, false), do: contents

  defp drop_partial_prefix(contents, true) do
    case :binary.match(contents, "\n") do
      {index, 1} -> binary_part(contents, index + 1, byte_size(contents) - index - 1)
      :nomatch -> ""
    end
  end

  defp decode_lines(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jsonl.decode_line(line) do
        {:ok, record} -> [record]
        :skip -> []
      end
    end)
  end
end
