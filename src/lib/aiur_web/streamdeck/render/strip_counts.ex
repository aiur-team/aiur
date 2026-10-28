defmodule AiurWeb.Streamdeck.Render.StripCounts do
  @moduledoc "Pure count-band ordering and windowing over the authoritative Deck counts."

  import AiurWeb.Streamdeck.Render.Svg, only: [field: 2]

  @priority ~w(error command retrying active ci_wait usage_limited parked paused)
  @pass_through ~w(blocked body-fix ci-red handed-off merge-queued paused-agent paused-decision paused-usage-limit retries)
  @order @priority ++ @pass_through ++ ["unknown"]

  @spec model(map() | nil, integer()) :: map()
  def model(counts, offset \\ 0) do
    by_state = field(counts, :by_state)
    status = status(counts, by_state)
    chips = chips(by_state)
    overflow = length(chips) > 8
    visible_count = if overflow, do: 7, else: 8
    offset = if overflow, do: offset |> max(0) |> min(length(chips) - visible_count), else: 0

    %{
      status: status,
      chips: chips,
      visible: Enum.slice(chips, offset, visible_count),
      more: if(overflow, do: length(chips) - visible_count, else: 0),
      offset: offset,
      backlog: %{queued: field(counts, :queued), not_queued: field(counts, :not_queued)}
    }
  end

  defp status(counts, by_state) when is_map(by_state) do
    valid = Enum.all?(by_state, fn {_state, count} -> is_integer(count) and count >= 0 end)

    if valid and field(counts, :status) in ["ok", "stale"], do: field(counts, :status), else: "unavailable"
  end

  defp status(_counts, _by_state), do: "unavailable"

  defp chips(by_state) when is_map(by_state) do
    by_state =
      Enum.reduce(by_state, %{}, fn {state, count}, acc ->
        state = if state in @order, do: state, else: "unknown"
        if is_integer(count) and count > 0, do: Map.update(acc, state, count, &(&1 + count)), else: acc
      end)

    Enum.flat_map(@order, fn state ->
      case Map.get(by_state, state) do
        count when is_integer(count) and count > 0 -> [%{state: state, count: count}]
        _ -> []
      end
    end)
  end

  defp chips(_by_state), do: []
end
