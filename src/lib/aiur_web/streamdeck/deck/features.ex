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
    total = field(entry, :total)
    pct = if known and total > 0, do: div(field(entry, :closed) * 100, total), else: :unknown
    observed_at = field(entry, :observed_at) || field(block, :observed_at)
    age = if is_integer(observed_at), do: "#{div(max(now - observed_at, 0), 60_000)}m", else: "—"
    sections = Map.put(field(window, :sections, %{}), :features, field(window, :features, %{}))

    %{
      id: key,
      key: key,
      feature: slug,
      label: field(feature, :label) || key,
      pct: pct,
      bar: if(known, do: Map.new([:closed, :open, :ci_wait, :unpublished, :total], &{&1, field(entry, &1)}), else: :unknown),
      ci_wait: if(is_integer(field(entry, :ci_wait)) and field(entry, :ci_wait) > 0, do: field(entry, :ci_wait)),
      reason: field(entry, :reason) || field(block, :reason) || if(!known, do: "Progress unavailable"),
      observed_at: observed_at,
      strip: "#{count(entry, :closed)}/#{count(entry, :total)} closed · #{count(entry, :unpublished)} not published · age #{age}",
      tickets: Tickets.keys(sections, {:feature, slug})
    }
  end

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
