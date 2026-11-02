defmodule AiurWeb.Streamdeck.Deck.Epics do
  @moduledoc "General-epic keys from the shared Build snapshot, with label-matched drill-in."
  alias AiurWeb.Streamdeck.Deck.{Counts, Tickets}

  @spec read(keyword()) :: map()
  def read(opts \\ []) do
    case Keyword.get_lazy(opts, :window, fn -> Counts.window(opts) end) do
      {:ok, window} -> project(window)
      _ -> %{status: "unavailable", keys: [], message: "Epics unavailable"}
    end
  end

  defp project(window) do
    progress = field(window, :epic_progress) || %{}
    sections = field(window, :sections) || %{}

    keys =
      (field(window, :epics) || %{})
      # Catalogue marks the same general epics that Build selects with !epic.feature.
      |> Enum.filter(fn {key, epic} -> key != "unsorted" and field(epic, :general) == true end)
      |> Enum.map(fn {key, epic} -> key(key, epic, Map.get(progress, key), sections) end)
      |> Enum.sort_by(fn key -> {key.remaining == :unknown, if(is_integer(key.remaining), do: -key.remaining, else: 0), String.downcase(key.title), key.title} end)

    has_members? =
      Enum.any?(keys, fn key ->
        total = field(Map.get(progress, key.id), :total)
        is_nil(total) or total > 0
      end)

    keys = if has_members?, do: keys, else: []

    %{status: "ok", keys: keys, message: if(keys == [], do: "No epics configured. Define build_order.general_epics")}
  end

  defp key(id, epic, progress, sections) do
    open = field(progress, :open)
    total = field(progress, :total)
    closed = field(progress, :closed)
    known? = Enum.all?([open, total, closed], &is_integer/1)
    pct = if known?, do: if(total == 0, do: 0, else: div(closed * 100, total))
    of = if known?, do: "#{open}/#{total}", else: "—"
    reason = if !known?, do: field(progress, :reason) || "Progress unavailable"

    %{
      id: id,
      key: id,
      title: field(epic, :label),
      label: if(known?, do: "#{open} remaining · #{of}", else: "— · #{reason}"),
      icon: field(epic, :icon),
      accent: epic_accent(field(epic, :hue)),
      face: :idle,
      bucket: :stuck,
      remaining: if(known?, do: open, else: :unknown),
      of: of,
      pct: pct,
      reason: reason,
      observed_at: field(progress, :observed_at),
      progress_percent: pct,
      progress_freshness: if(known?, do: "fresh", else: "unknown"),
      tickets: Tickets.keys(sections, {:epic, id})
    }
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil
  defp epic_accent(hue) when is_number(hue) and hue >= 0 and hue < 360, do: "hsl(#{hue} 65% 42%)"
  defp epic_accent(_), do: nil
end
