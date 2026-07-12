defmodule Aiur.DecisionMetrics.Window do
  @moduledoc "Bounded recency and dedup windows shared by Decision metrics workers."

  @enforce_keys [:limit]
  defstruct limit: nil, members: MapSet.new(), order: :queue.new(), count: 0

  @type t :: %__MODULE__{
          limit: pos_integer(),
          members: MapSet.t(String.t()),
          order: :queue.queue(String.t()),
          count: non_neg_integer()
        }

  @spec new(pos_integer(), [String.t()]) :: t()
  def new(limit, event_ids \\ []) when is_integer(limit) and limit > 0 and is_list(event_ids) do
    Enum.reduce(event_ids, %__MODULE__{limit: limit}, &put(&2, &1))
  end

  @spec member?(t(), String.t()) :: boolean()
  def member?(%__MODULE__{} = window, event_id), do: MapSet.member?(window.members, event_id)

  @spec put(t(), String.t()) :: t()
  def put(%__MODULE__{} = window, event_id) when is_binary(event_id) do
    if member?(window, event_id) do
      window
    else
      window
      |> insert(event_id)
      |> evict_oldest()
    end
  end

  @spec ids(t()) :: [String.t()]
  def ids(%__MODULE__{} = window), do: :queue.to_list(window.order)

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = window), do: window.count

  @doc "Keeps the most recently observed samples and returns their identities."
  @spec recent(map(), pos_integer()) :: {map(), [String.t()]}
  def recent(samples, limit) when map_size(samples) <= limit do
    {samples, Map.keys(samples)}
  end

  def recent(samples, limit) when is_map(samples) and is_integer(limit) and limit > 0 do
    retained =
      samples
      |> Enum.sort_by(fn {_decision_id, sample} -> observed_sort_key(sample.last_observed_at) end, :desc)
      |> Enum.take(limit)

    {Map.new(retained), Enum.map(retained, &elem(&1, 0))}
  end

  defp insert(window, event_id) do
    %{
      window
      | members: MapSet.put(window.members, event_id),
        order: :queue.in(event_id, window.order),
        count: window.count + 1
    }
  end

  defp evict_oldest(%{count: count, limit: limit} = window) when count > limit do
    {{:value, oldest}, order} = :queue.out(window.order)
    %{window | members: MapSet.delete(window.members, oldest), order: order, count: count - 1}
  end

  defp evict_oldest(window), do: window

  defp observed_sort_key(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp observed_sort_key(_at), do: 0
end
