defmodule Aiur.Conversation.HistoryAnchors do
  @moduledoc false
  alias Aiur.Conversation.Anchors

  @spec read(map(), keyword()) :: {:ok, [map()]} | {:error, :unavailable}
  def read(snapshot, opts) do
    with {:ok, bytes} <- File.read(Path.join(snapshot.dir, "anchors.jsonl")),
         {:ok, anchors} <- decode(bytes) do
      {:ok, anchors |> Anchors.strongest() |> Enum.filter(&selected?(&1, opts))}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp decode(bytes) do
    # A concurrent append may have an incomplete final record; never repair it.
    lines = bytes |> String.split("\n") |> Enum.drop(-1)

    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, anchors} ->
      case Jason.decode(line) do
        {:ok, %{"event" => %{"event_id" => _}, "kind" => _, "precision" => precision, "conversation_id" => _} = anchor}
        when precision in ["unanchored", "observed", "causal", "exact"] ->
          {:cont, {:ok, [anchor | anchors]}}

        _ ->
          {:halt, {:error, :unavailable}}
      end
    end)
    |> case do
      {:ok, anchors} -> {:ok, Enum.reverse(anchors)}
      error -> error
    end
  end

  defp selected?(anchor, opts) do
    kinds = Keyword.get(opts, :kinds)
    range = Keyword.get(opts, :pos_range)
    since = Keyword.get(opts, :since)
    (is_nil(kinds) or anchor["kind"] in kinds) and in_range?(anchor["pos"], range) and since?(anchor["event"]["observed_at"], since)
  end

  defp in_range?(_pos, nil), do: true
  defp in_range?(pos, {first, last}), do: is_integer(pos) and pos >= first and pos <= last
  defp in_range?(pos, %Range{} = range), do: is_integer(pos) and pos in range
  defp since?(_time, nil), do: true
  defp since?(time, %DateTime{} = since), do: since?(time, DateTime.to_iso8601(since))

  defp since?(time, since) when is_binary(time) and is_binary(since) do
    with {:ok, time, _} <- DateTime.from_iso8601(time),
         {:ok, since, _} <- DateTime.from_iso8601(since) do
      DateTime.compare(time, since) != :lt
    else
      _ -> false
    end
  end

  defp since?(_time, _since), do: false
end
