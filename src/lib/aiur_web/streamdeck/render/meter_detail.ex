defmodule AiurWeb.Streamdeck.Render.MeterDetail do
  @moduledoc "Pure account keys and provider summary for a meter detail frame."
  alias AiurWeb.Streamdeck.Render
  alias AiurWeb.Streamdeck.Render.Svg
  import Svg, only: [element: 2, element: 3, text: 4, field: 2, field: 3]

  @spec frame(map(), map(), integer(), non_neg_integer()) :: map()
  def frame(detail, summary, now_ms, page \\ 0) do
    accounts = field(detail, :accounts, [])

    keys =
      Enum.map(0..7, fn index ->
        case Enum.at(accounts, page * 8 + index) do
          nil -> nil
          account -> key(account, now_ms)
        end
      end)

    label = "#{field(detail, :provider)} · #{field(summary, :summary_label) || "#{length(accounts)} accounts"}"

    regions = [
      %{
        x: 0,
        width: 800,
        label: label,
        parts: [
          %{kind: :text_line, text: label, y: 24, size: 16},
          %{kind: :text_line, text: "5h and weekly remaining · Hold dial 4 to return", y: 64, size: 14}
        ]
      }
    ]

    %{keys: keys, strip: Render.strip(regions)}
  end

  @spec key(map(), integer()) :: map()
  def key(account, now_ms) do
    stale = field(account, :freshness) == "stale"
    label = field(account, :name) <> if(stale, do: " stale", else: "")

    content = [
      element("rect", width: 120, height: 120, rx: 12, fill: "#101318"),
      element("defs", [], element("pattern", [id: "unknown", width: 6, height: 6, patternUnits: "userSpaceOnUse"], element("path", d: "M0 6L6 0", stroke: "#9298a3", "stroke-width": 2))),
      element("g", [opacity: if(stale, do: "0.45", else: "1")], [
        text(String.slice(label, 0, 19), 6, 18, 10),
        window(field(account, :session), "5h", 38, now_ms),
        window(field(account, :weekly), "Weekly", 79, now_ms)
      ])
    ]

    Svg.image(content, 120, 120, label)
  end

  defp window(window, label, y, now_ms) do
    value = field(window, :remaining_percent)
    stale = field(window, :freshness) == "stale"
    reading = if is_number(value), do: "#{value}% left", else: "—"

    [
      element("g", [opacity: if(stale, do: "0.45", else: "1")], [
        text(label <> if(stale, do: " stale", else: ""), 6, y, 9),
        text("#{reading} · #{reset_label(field(window, :reset_at), now_ms)}", 6, y + 13, 9),
        element("rect", x: 6, y: y + 18, width: 108, height: 6, fill: "#555b66"),
        bar(value, y + 18)
      ])
    ]
  end

  defp bar(value, y) when is_number(value), do: element("rect", "data-part": "remaining-fill", x: 6, y: y, width: 108 * min(max(value, 0), 100) / 100, height: 6, fill: "#3fb950")
  defp bar(_, y), do: element("rect", "data-part": "unknown-hatch", x: 6, y: y, width: 108, height: 6, fill: "url(#unknown)")
  defp reset_label(nil, _now), do: "—"
  defp reset_label(at, now) when at <= now, do: "reset due"
  defp reset_label(at, now) when at - now >= 86_400_000, do: "#{ceil((at - now) / 86_400_000)}d"
  defp reset_label(at, now) when at - now >= 3_600_000, do: "#{ceil((at - now) / 3_600_000)}h"
  defp reset_label(at, now), do: "#{ceil((at - now) / 60_000)}m"
end
