defmodule Aiur.Jsonl do
  @moduledoc """
  Decode-or-skip helpers for line-oriented JSON (JSONL / ndjson) logs and
  transcripts. `decode_line/1` accepts only JSON objects — a malformed line
  or a non-object JSON value is `:skip`, never a raise. Callers that need a
  different malformed-line policy keep a one-line adapter over this module.
  """

  @spec decode_line(binary()) :: {:ok, map()} | :skip
  def decode_line(line) when is_binary(line) do
    case line |> String.trim() |> Jason.decode() do
      {:ok, record} when is_map(record) -> {:ok, record}
      _ -> :skip
    end
  end

  @spec stream(Path.t()) :: Enumerable.t()
  def stream(path) when is_binary(path) do
    path
    |> File.stream!(:line)
    |> Stream.flat_map(fn line ->
      case decode_line(line) do
        {:ok, record} -> [record]
        :skip -> []
      end
    end)
  end
end
