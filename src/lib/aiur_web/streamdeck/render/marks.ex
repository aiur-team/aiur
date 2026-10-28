defmodule AiurWeb.Streamdeck.Render.Marks do
  @moduledoc false

  alias AiurWeb.EpicIcon
  alias AiurWeb.Streamdeck.Render.Svg

  @marks (for {provider, file} <- [
                {"claude", "claude-symbol.svg"},
                {"codex", "codex-color.svg"},
                {"deepseek", "deepseek.svg"},
                {"kimi", "kimi.svg"},
                {"openrouter", "openrouter.svg"},
                {"muse", "muse.svg"}
              ],
              into: [] do
            path = Path.expand("../../../../priv/static/#{file}", __DIR__)
            @external_resource Path.relative_to(path, File.cwd!(), force: true)
            svg = File.read!(path)
            [{provider, svg}, {"/provider-assets/#{file}", svg}]
          end)
         |> List.flatten()
         |> Map.new()

  @spec epic(term(), String.t()) :: iodata()
  def epic(lane, accent) do
    Svg.element("g", [color: accent], embed(EpicIcon.svg(lane), 13, 13, 18))
  end

  @spec provider(term(), number(), number(), number(), term()) :: iodata()
  def provider(provider, x, y, size, logo \\ nil) do
    name = provider |> to_string() |> String.trim() |> String.downcase()

    case Map.get(@marks, logo) || Map.get(@marks, name) do
      nil ->
        [
          Svg.element("rect",
            x: x,
            y: y,
            width: size,
            height: size,
            rx: size / 2,
            fill: "#5a6273"
          ),
          Svg.text(
            name |> String.first() |> Kernel.||("?") |> String.upcase(),
            x + size / 2,
            y + size * 0.75,
            size * 0.7,
            "text-anchor": "middle"
          )
        ]

      svg ->
        embed(svg, x, y, size)
    end
  end

  # Trusted allowlisted marks become groups, leaving one SVG root per key.
  defp embed(svg, x, y, size) do
    svg = String.trim(svg)
    [_, view_box] = Regex.run(~r/viewBox="([^"]+)"/, svg)

    [vx, vy, width, height] =
      view_box |> String.split() |> Enum.map(&(Float.parse(&1) |> elem(0)))

    scale = min(size / width, size / height)
    left = x + (size - width * scale) / 2
    top = y + (size - height * scale) / 2
    transform = "translate(#{left} #{top}) scale(#{scale}) translate(#{-vx} #{-vy})"

    group =
      svg
      |> String.replace_prefix("<svg", "<g")
      |> String.replace_suffix("</svg>", "</g>")
      |> String.replace(~r/\s(?:viewBox|xmlns)="[^"]*"/, "")

    Svg.element("g", [transform: transform], group)
  end
end
