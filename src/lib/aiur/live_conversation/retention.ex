defmodule Aiur.LiveConversation.Retention do
  @moduledoc false

  alias Aiur.LiveConversation.Compactor

  @message_limit 80
  @snapshot_byte_limit 64_000
  @ended_generation_limit 16
  @retained_snapshot_limit 128

  @spec retain(map(), (map() -> map())) :: map()
  def retain(snapshot, public_fun) when is_function(public_fun, 1) do
    {messages, evicted} = trim_messages(snapshot, snapshot.messages, 0, public_fun)

    %{
      snapshot
      | messages: messages,
        seen: Compactor.reindex(messages),
        evicted_count: snapshot.evicted_count + evicted,
        truncated?: snapshot.truncated? or evicted > 0
    }
  end

  @spec retain_snapshots(map()) :: map()
  def retain_snapshots(snapshots) do
    snapshots
    |> retain_ended_generations()
    |> retain_total_snapshots()
  end

  defp trim_messages(snapshot, messages, evicted, public_fun)
       when length(messages) > @message_limit do
    trim_messages(snapshot, tl(messages), evicted + 1, public_fun)
  end

  defp trim_messages(snapshot, [_message | rest] = messages, evicted, public_fun) do
    if snapshot_bytes(snapshot, messages, evicted, public_fun) > @snapshot_byte_limit do
      trim_messages(snapshot, rest, evicted + 1, public_fun)
    else
      {messages, evicted}
    end
  end

  defp trim_messages(_snapshot, [], evicted, _public_fun), do: {[], evicted}

  defp snapshot_bytes(snapshot, messages, evicted, public_fun) do
    snapshot
    |> Map.put(:messages, messages)
    |> Map.update!(:evicted_count, &(&1 + evicted))
    |> Map.update!(:truncated?, &(&1 or evicted > 0))
    |> public_fun.()
    |> Jason.encode_to_iodata!()
    |> IO.iodata_length()
  end

  defp retain_ended_generations(snapshots) do
    ended =
      snapshots
      |> Enum.filter(fn {_key, snapshot} -> snapshot.state == :ended end)
      |> Enum.sort_by(&retention_order/1)

    ended
    |> Enum.take(max(length(ended) - @ended_generation_limit, 0))
    |> Enum.reduce(snapshots, fn {key, _snapshot}, acc -> Map.delete(acc, key) end)
  end

  defp retain_total_snapshots(snapshots)
       when map_size(snapshots) <= @retained_snapshot_limit,
       do: snapshots

  defp retain_total_snapshots(snapshots) do
    snapshots
    |> Enum.sort_by(&retention_order/1)
    |> Enum.take(map_size(snapshots) - @retained_snapshot_limit)
    |> Enum.reduce(snapshots, fn {key, _snapshot}, acc -> Map.delete(acc, key) end)
  end

  defp retention_order({key, snapshot}) do
    {DateTime.to_unix(snapshot.observed_at, :microsecond), inspect(key)}
  end
end
