defmodule AiurWeb.Streamdeck.Render.Svg do
  @moduledoc false

  @spec escape(term()) :: String.t()
  def escape(value) do
    value
    |> to_string()
    |> String.replace(~r/[^\x{9}\x{A}\x{D}\x{20}-\x{D7FF}\x{E000}-\x{FFFD}\x{10000}-\x{10FFFF}]/u, "")
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  @spec element(String.t(), keyword(), iodata()) :: iodata()
  def element(name, attrs, children \\ []) do
    ["<", name, Enum.map(attrs, fn {key, value} -> [" ", to_string(key), "=\"", escape(value), "\""] end), ">", children, "</", name, ">"]
  end

  @spec text(term(), number(), number(), number(), keyword()) :: iodata()
  def text(value, x, y, size, attrs \\ []) do
    element("text", [x: x, y: y, "font-size": size] ++ attrs, escape(value))
  end

  @spec image(iodata(), pos_integer(), pos_integer(), String.t()) :: map()
  def image(content, width, height, label) do
    svg =
      element(
        "svg",
        [xmlns: "http://www.w3.org/2000/svg", width: width, height: height, viewBox: "0 0 #{width} #{height}", "font-family": "JetBrains Mono, monospace", fill: "#f1f3f6"],
        [element("title", [], escape(label)), content]
      )
      |> IO.iodata_to_binary()
      |> scope_ids()

    %{svg: svg, hash: :crypto.hash(:sha256, svg) |> Base.encode16(case: :lower) |> binary_part(0, 16), label: label}
  end

  # Inline SVG ids share the browser document, unlike isolated HID images.
  defp scope_ids(svg) do
    prefix = "sd-" <> (:crypto.hash(:sha256, svg) |> Base.encode16(case: :lower) |> binary_part(0, 16)) <> "-"
    svg = Regex.replace(~r/\bid="([^"]+)"/, svg, fn _all, id -> ~s(id="#{prefix}#{id}") end)
    svg = Regex.replace(~r/((?:fill|stroke|filter|clip-path|mask)=")url\(#([^)]+)\)/, svg, fn _all, attr, id -> attr <> "url(##{prefix}#{id})" end)
    Regex.replace(~r/\bhref="#([^"]+)"/, svg, fn _all, id -> ~s(href="##{prefix}#{id}") end)
  end

  @spec budget(number(), number(), number()) :: pos_integer()
  def budget(width, pad, size), do: max(floor((width - 2 * pad) / (0.6 * size)), 1)

  @spec wrap(String.t(), pos_integer(), pos_integer()) :: [String.t()]
  def wrap(value, budget, max_lines) do
    lines =
      value
      |> String.split()
      |> Enum.flat_map(&(String.graphemes(&1) |> Enum.chunk_every(budget) |> Enum.map(fn chars -> Enum.join(chars) end)))
      |> Enum.reduce([], &add_word(&1, &2, budget))
      |> Enum.reverse()

    if length(lines) > max_lines do
      Enum.take(lines, max_lines - 1) ++ [String.slice(Enum.at(lines, max_lines - 1), 0, budget - 1) <> "…"]
    else
      lines
    end
  end

  defp add_word(word, [current | rest] = lines, budget) do
    if String.length(current <> " " <> word) <= budget, do: [current <> " " <> word | rest], else: [word | lines]
  end

  defp add_word(word, [], _budget), do: [word]

  @spec field(map() | nil, atom(), term()) :: term()
  def field(map, key, default \\ nil)
  def field(nil, _key, default), do: default
  def field(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
