defmodule AiurWeb.DashboardCssThemeTest do
  use ExUnit.Case, async: true

  @css Path.expand("../../priv/static/dashboard.css", __DIR__)

  # A literal hex in a `color:` declaration cannot be theme-aware: the same ink
  # renders against both the dark and the light surfaces. The nav count badge
  # shipped `color: #f5b8a8`, which measured 1.19:1 in light mode — the count
  # was invisible. The themed `--*-ink` tokens carry a per-theme value and are
  # the only correct home for text colour.
  #
  # These are the literals that predate the rule. The list is debt, not a
  # standard: every entry is a dark-tuned ink that is low-contrast in light
  # mode. Shrink it; do not grow it.
  @known_literal_text_colors [
    "#1a1200",
    "#6bd6a6",
    "#6bd6a6",
    "#6bd6a6",
    "#6bd6a6",
    "#7fd4e0",
    "#8fbcff",
    "#d98f5b",
    "#e3b341",
    "#e3b341",
    "#e3b341",
    "#fff",
    "#fff"
  ]

  test "no new hardcoded text colors are introduced" do
    found = literal_text_colors()

    assert found == @known_literal_text_colors, """
    The set of literal `color: #hex` declarations in dashboard.css changed.

    Added:   #{inspect(found -- @known_literal_text_colors)}
    Removed: #{inspect(@known_literal_text_colors -- found)}

    A literal hex cannot adapt across themes. Use a themed token
    (--fg, --muted, --accent-ink, --attention-ink, --blocking-ink, --good-ink,
    --super-ink) instead. If you fixed one, delete it from
    @known_literal_text_colors — the list is expected to shrink.
    """
  end

  # The specific regression: this badge counts blocking decisions, so it belongs
  # on the themed --blocking-* family, which is legible in both themes.
  test "the nav attention badge uses themed blocking tokens" do
    rule = css_rule(".shell-nav-count.is-attention")

    assert rule =~ "var(--blocking-soft)"
    assert rule =~ "var(--blocking-ink)"

    css = File.read!(@css)
    refute css =~ "#f5b8a8", "the dark-only salmon ink is back"
    refute css =~ ~r/color:\s*#f2836b/, "the dark-only salmon is back as a text colour"
  end

  # The Stream Deck chassis (#1352) is painted dark in both themes, so it opts
  # out of the light palette for its interior. That opt-out is a manual list,
  # and an omission is invisible to the literal-hex test above: the ink is a
  # themed token, it just resolves to the wrong theme's value. The "Blocked"
  # dependency chip shipped dark-red-on-near-black (~2:1) twice for exactly
  # this reason. Every token the chassis paints with must be pinned here, and
  # pinned to the dark `:root` value byte-for-byte.
  # Pinned back to the dark `:root` value exactly — these are the accent inks
  # the chassis paints text, dots and focus rings with.
  @streamdeck_dark_root_pins ~w(
    --accent
    --accent-ink
    --attention-ink
    --blocking-ink
    --blocking-soft
    --good
    --super
  )

  # Pinned to chassis-specific values rather than `:root` — the key face is
  # darker than the dashboard surface, so body text is pushed brighter than
  # `--fg`/`--muted` would be. Presence is the contract, not the value.
  @streamdeck_chassis_pins ~w(--fg --muted)

  test "the light-mode Stream Deck chassis pins every token it paints ink with" do
    pinned = declarations(css_rule(~s(html[data-theme="light"] .sd-device)))
    dark_root = declarations(css_rule(":root"))

    for token <- @streamdeck_chassis_pins ++ @streamdeck_dark_root_pins do
      assert Map.has_key?(pinned, token), """
      html[data-theme="light"] .sd-device does not pin #{token}.

      An unpinned token inherits the light-theme :root value and paints dark ink
      on the near-black key face. Add
      `#{token}: #{Map.get(dark_root, token, "<the dark :root value>")};`
      to that block in dashboard.css.
      """
    end

    for token <- @streamdeck_dark_root_pins do
      assert Map.fetch!(pinned, token) == Map.fetch!(dark_root, token),
             "html[data-theme=\"light\"] .sd-device pins #{token} to " <>
               "#{inspect(Map.fetch!(pinned, token))}, but the dark :root value is " <>
               "#{inspect(Map.fetch!(dark_root, token))}. The pin must match :root exactly."
    end
  end

  defp declarations(rule) do
    ~r/(--[a-z0-9-]+)\s*:\s*([^;]+);/
    |> Regex.scan(rule)
    |> Map.new(fn [_full, name, value] -> {name, String.trim(value)} end)
  end

  defp literal_text_colors do
    @css
    |> File.read!()
    |> then(&Regex.scan(~r/^\s*color:\s*(#[0-9a-fA-F]{3,8})\s*;/m, &1))
    |> Enum.map(fn [_full, hex] -> String.downcase(hex) end)
    |> Enum.sort()
  end

  defp css_rule(selector) do
    css = File.read!(@css)
    [_before, rest] = String.split(css, selector <> " {", parts: 2)
    [body, _after] = String.split(rest, "}", parts: 2)
    body
  end
end
