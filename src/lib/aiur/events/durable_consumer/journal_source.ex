defmodule Aiur.Events.DurableConsumer.JournalSource do
  @moduledoc """
  `Aiur.Events.DurableConsumer.Source` over `Aiur.Events.Journal` for a journal
  whose records carry a dense `"seq"`. `subscribe/2` is a no-op: the journal's
  writer supplies the live path.
  """

  # aiur:event-bus-boundary-member

  @behaviour Aiur.Events.DurableConsumer.Source

  alias Aiur.Events.Journal

  @impl true
  def subscribe(_path, _consumer), do: :ok

  @impl true
  def replay(path, cursor, limit) do
    # ponytail: re-reads the whole journal per batch; fine until journals are large.
    case Journal.replay(path, &{:ok, &1}) do
      {:ok, []} -> {:ok, []}
      {:ok, [first | _] = records} -> window(records, position(first), cursor, limit)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def position(record), do: Map.fetch!(record, "seq")

  defp window(records, oldest, cursor, limit) do
    head = position(List.last(records))

    if oldest > cursor + 1 or head < cursor do
      {:reset, oldest}
    else
      {:ok, records |> Enum.filter(&(position(&1) > cursor)) |> Enum.take(limit)}
    end
  end
end
