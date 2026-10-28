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
              into: %{} do
            path = Path.expand("../../../../priv/static/#{file}", __DIR__)
            @external_resource Path.relative_to(path, File.cwd!(), force: true)
            {provider, File.read!(path)}
          end)

  @spec epic(term(), String.t()) :: iodata()
  def epic(lane, accent) do
    svg = lane |> EpicIcon.svg() |> String.replace_prefix("<svg", ~s(<svg width="24" height="24"))
    Svg.element("g", [transform: "translate(13 13) scale(0.75)", color: accent], svg)
  end

  @spec provider(term(), number(), number(), number()) :: iodata()
  def provider(provider, x, y, size) do
    name = provider |> to_string() |> String.trim() |> String.downcase()

    case Map.get(@marks, name) do
      nil ->
        [
          Svg.element("rect", x: x, y: y, width: size, height: size, rx: size / 2, fill: "#5a6273"),
          Svg.text(name |> String.first() |> Kernel.||("?") |> String.upcase(), x + size / 2, y + size * 0.75, size * 0.7, "text-anchor": "middle")
        ]

      svg ->
        # The vendored SVG is trusted; input only selects an allowlisted asset.
        svg
        |> String.replace(~r/\A<svg\b[^>]*>/, fn root ->
          root = String.replace(root, ~r/\s(?:width|height)="[^"]*"/, "")
          String.replace_prefix(root, "<svg", ~s(<svg x="#{x}" y="#{y}" width="#{size}" height="#{size}"))
        end)
    end
  end
end
