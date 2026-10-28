defmodule Aiur.Conversation.HistoryPage do
  @moduledoc false
  alias Aiur.Conversation.HistoryReader

  @cursors [:before, :after, :around, :from_start, :tail]
  @scan_limit 5_000

  @spec options(keyword()) :: {:ok, {atom(), non_neg_integer() | true}, pos_integer()} | {:error, :invalid_cursor | :invalid_limit}
  def options(opts) do
    cursors = Keyword.take(opts, @cursors)
    cursor = List.first(cursors, {:tail, true})
    limit = Keyword.get(opts, :limit, 50)

    cond do
      length(cursors) > 1 or not valid_cursor?(cursor) -> {:error, :invalid_cursor}
      not is_integer(limit) or limit < 1 or limit > 200 -> {:error, :invalid_limit}
      true -> {:ok, cursor, limit}
    end
  end

  defp valid_cursor?({name, true}) when name in [:tail, :from_start], do: true
  defp valid_cursor?({:after, pos}), do: is_integer(pos) and pos >= 0
  defp valid_cursor?({name, pos}) when name in [:before, :around], do: is_integer(pos) and pos > 0
  defp valid_cursor?(_), do: false

  @spec read(map(), tuple(), pos_integer(), keyword()) :: {:ok, map()} | {:error, :not_found | :unavailable}
  def read(%{head: %{"last_pos" => head}}, {:around, pos}, _limit, _opts) when pos > head, do: {:error, :not_found}

  def read(snapshot, cursor, limit, opts) do
    with {:ok, entries, low, high} <- select(snapshot, cursor, limit, opts),
         {:ok, sessions} <- HistoryReader.sessions(snapshot),
         {:ok, complete?} <- complete?(snapshot, sessions) do
      {:ok,
       %{
         entries: entries,
         sessions: overlapping(sessions, entries),
         prev_cursor: if(low > 1, do: low),
         next_cursor: if(high < snapshot.head["last_pos"], do: high),
         head_pos: snapshot.head["last_pos"],
         complete_from_start: complete?,
         observed_at: DateTime.utc_now()
       }}
    end
  end

  defp select(snapshot, {:around, pos}, limit, opts) do
    half = div(limit, 2)

    with {:ok, earlier, low, _} <- scan(snapshot, 1, pos - 1, :backward, half, opts, div(@scan_limit, 2)),
         {:ok, later, _, high} <- scan(snapshot, pos, snapshot.head["last_pos"], :forward, limit - half, opts, div(@scan_limit, 2)) do
      {:ok, earlier ++ later, low, high}
    end
  end

  defp select(snapshot, cursor, limit, opts) do
    head = snapshot.head["last_pos"]

    {from, to, direction} =
      case cursor do
        {:tail, true} -> {1, head, :backward}
        {:from_start, true} -> {1, head, :forward}
        {:before, pos} -> {1, min(pos - 1, head), :backward}
        {:after, pos} -> {min(pos, head) + 1, head, :forward}
      end

    scan(snapshot, from, to, direction, limit, opts, @scan_limit)
  end

  defp scan(_snapshot, _from, to, :backward, 0, _opts, _cap), do: {:ok, [], to + 1, to}

  defp scan(snapshot, from, to, direction, limit, opts, cap) do
    kinds = Keyword.get(opts, :kinds)

    result =
      snapshot
      |> HistoryReader.entries(from, to, direction)
      |> Enum.reduce_while({[], 0, 0, nil}, fn
        {:ok, entry}, {acc, matched, scanned, _last} ->
          keep? = is_nil(kinds) or entry.kind == "gap" or entry.kind in kinds
          acc = if keep?, do: [Map.from_struct(entry) | acc], else: acc
          matched = if keep?, do: matched + 1, else: matched
          state = {acc, matched, scanned + 1, entry.pos}
          if matched == limit or scanned + 1 == cap, do: {:halt, state}, else: {:cont, state}

        _, _ ->
          {:halt, {:error, :unavailable}}
      end)

    case result do
      {:error, _} = error ->
        error

      {acc, _matched, _scanned, last} ->
        entries = if direction == :forward, do: Enum.reverse(acc), else: acc
        low = if direction == :backward, do: last || from, else: from
        high = if direction == :forward, do: last || to, else: to
        # Continuations advance over filtered positions, even when the page is empty.
        low = if entries != [] and direction == :forward, do: hd(entries).pos, else: low
        high = if entries != [] and direction == :backward, do: List.last(entries).pos, else: high
        {:ok, entries, low, high}
    end
  end

  defp overlapping(_sessions, []), do: []

  defp overlapping(sessions, entries) do
    first = hd(entries).pos
    last = List.last(entries).pos
    Enum.filter(sessions, &(&1.first_pos <= last and &1.last_pos >= first))
  end

  defp complete?(snapshot, sessions) do
    case snapshot |> HistoryReader.entries(1, 1, :forward) |> Enum.take(1) do
      [] ->
        {:ok, not Enum.any?(Enum.take(sessions, 1), &(&1.start_reason == "import"))}

      [{:ok, entry}] ->
        pre_journal = entry.kind == "gap" and Map.get(entry.meta, "reason", Map.get(entry.meta, :reason)) == "pre_journal"
        {:ok, not pre_journal and not Enum.any?(Enum.take(sessions, 1), &(&1.start_reason == "import"))}

      _ ->
        {:error, :unavailable}
    end
  end
end
