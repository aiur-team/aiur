defmodule AiurWeb.Streamdeck.Deck.Features do
  @moduledoc "Parent feature progress keys from the shared Build window, never weighted stats."
  alias AiurWeb.Streamdeck.Deck.{Counts, Tickets}
  import AiurWeb.Streamdeck.Render.Svg, only: [field: 2, field: 3]

  @spec read(keyword()) :: map()
  def read(opts \\ []) do
    case Keyword.get_lazy(opts, :window, fn -> Counts.window(opts) end) do
      {:ok, window} -> %{status: "ok", keys: keys(window, Keyword.get(opts, :now, System.system_time(:millisecond)))}
      _ -> %{status: "unavailable", keys: []}
    end
  end

  @spec keys(map(), integer()) :: [map()]
  def keys(window, now) do
    block = field(window, :feature_progress, %{})
    entries = field(block, :features, %{})
    order = field(window, :order, [])
    ordered = Enum.filter(order, &Map.has_key?(entries, &1))

    catalogue = field(window, :features, %{})

    slugs =
      (ordered ++ Enum.sort(Map.keys(entries) -- ordered))
      |> Enum.map(fn key -> field(entries[key], :feature) || field(field(field(window, :epics, %{}), key), :feature) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    slugs = slugs ++ Enum.sort(Map.keys(catalogue) -- slugs)
    Enum.map(slugs, &key(&1, catalogue, entries, window, block, now))
  end

  defp key(slug, catalogue, entries, window, block, now) do
    feature = Map.get(catalogue, slug, %{})
    lanes = Enum.map(field(feature, :epics, []), &Map.get(entries, &1, %{}))
    entry = aggregate(lanes)
    key = slug
    known = Enum.all?([:closed, :open, :ci_wait, :unpublished, :total], &is_integer(field(entry, &1)))
    observed_at = field(entry, :observed_at) || field(block, :observed_at)
    sections = Map.put(field(window, :sections, %{}), :features, field(window, :features, %{}))

    %{
      id: key,
      key: key,
      feature: slug,
      label: field(feature, :label) || key,
      pct: percent(entry, known),
      bar: if(known, do: Map.new([:closed, :open, :ci_wait, :unpublished, :total], &{&1, field(entry, &1)}), else: :unknown),
      ci_wait: badge(field(entry, :ci_wait)),
      reason: reason(entry, block, known),
      observed_at: observed_at,
      strip: "#{count(entry, :closed)}/#{count(entry, :total)} closed · #{count(entry, :unpublished)} not published · age #{age(observed_at, now)}",
      tickets: Tickets.keys(sections, {:feature, slug})
    }
  end

  defp percent(%{closed: closed, total: total}, true) when total > 0, do: div(closed * 100, total)
  defp percent(_entry, _known), do: :unknown
  defp badge(value) when is_integer(value) and value > 0, do: value
  defp badge(_value), do: nil
  defp age(observed, now) when is_integer(observed), do: "#{div(max(now - observed, 0), 60_000)}m"
  defp age(_unknown, _now), do: "—"
  defp reason(entry, block, known), do: field(entry, :reason) || field(block, :reason) || if(!known, do: "Progress unavailable")

  defp aggregate(lanes) do
    counts =
      Map.new([:closed, :open, :ci_wait, :unpublished, :total], fn name ->
        values = Enum.map(lanes, &field(&1, name))
        {name, if(values != [] and Enum.all?(values, &is_integer/1), do: Enum.sum(values))}
      end)

    observed = lanes |> Enum.map(&field(&1, :observed_at)) |> Enum.filter(&is_integer/1)
    Map.merge(counts, %{reason: Enum.find_value(lanes, &field(&1, :reason)), observed_at: Enum.min(observed, fn -> nil end)})
  end

  defp count(entry, name), do: field(entry, name) || "—"
end
