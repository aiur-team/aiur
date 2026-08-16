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
    "#e29b63",
    "#e3b341",
    "#e3b341",
    "#e3b341"
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
    --attention
    --attention-ink
    --blocking-ink
    --blocking-soft
    --good
    --good-ink
    --super
    --ack
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

  # A meter that has reached 100% used is critical: the fill turns red so an
  # exhausted window is never mistaken for a healthy one (#1532). The rule must
  # keep using the themed blocking token so it stays legible in both themes.
  test ".rs-meter is-critical uses the themed blocking fill" do
    rule = css_rule(".rs-meter > i.is-critical")
    assert rule =~ "var(--blocking)"
  end

  test "dashboard progress bars match the Stream Deck progress contract" do
    contract =
      Path.expand("../../../packages/streamdeck/src/key-face-contract.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    root = declarations(css_rule(":root"))
    assert root["--progress-fill"] == contract["progress"]["fill"]
    assert root["--progress-complete-fill"] == contract["progress"]["complete_fill"]

    assert css_rule(".ut-pbar > i") =~ "var(--progress-fill)"
    assert css_rule(".ut-pbar > i") =~ "min-width: 5px"
    assert css_rule(".ut-pbar > i.is-complete") =~ "var(--progress-complete-fill)"
    assert css_rule(".ut-pbar > i.is-stale") =~ "opacity: 0.5"
    refute @css |> File.read!() |> String.contains?(".ut-pbar > i.is-blocked")
    refute @css |> File.read!() |> String.contains?(".ut-pbar > i.has-alert")
    assert css_rule(".run-summary-progress-fill") =~ "var(--progress-fill)"
    assert css_rule(".run-summary-progress-fill.is-complete") =~ "var(--progress-complete-fill)"
    assert css_rule(".run-summary-progress-fill.is-stale") =~ "opacity: 0.5"
    assert css_rule(".sd-strip-cmd-progress > i") =~ "min-width: 0.34rem"
    assert css_rule(".sd-strip-cmd.is-progress-stale .sd-strip-cmd-progress > i") =~ "opacity: 0.5"
    assert css_rule(".sd-strip-cmd.is-progress-unknown .sd-strip-cmd-status::before") =~ "background: transparent"
    assert css_rule(".sd-strip-cmd.is-progress-unknown .sd-strip-cmd-progress") =~ "border: 1px dashed"
  end

  # Text on a filled control needs its own token pair: a fill tuned to carry
  # ink, and the ink itself. `.btn` used to paint `#fff` straight onto --accent,
  # which is 3.51:1 in the dark theme, and `.btn.danger` inherited that white
  # onto the pale --blocking salmon at 2.52:1. Both are themed now, so a future
  # edit that reaches back for a multi-line literal hex fails the debt test
  # above (a single-line `color: #hex` rule still slips past its anchor).
  test "filled buttons take their ink from themed on-fill tokens" do
    btn = css_rule(".btn")
    assert btn =~ "background: var(--accent-strong)"
    assert btn =~ "color: var(--on-accent)"

    assert css_rule(".btn.danger") =~ "color: var(--on-blocking)"
    assert css_rule(".blocking .decision-banner-cta") =~ "color: var(--on-blocking)"

    # --accent-strong exists because --accent is deliberately too bright to hold
    # text; keeping them distinct in the dark theme is the point of the token.
    dark = declarations(css_rule(":root"))
    assert Map.fetch!(dark, "--accent-strong") != Map.fetch!(dark, "--accent")
  end

  # The browser suite's axe pass asserts that no *rendered* pair fails, but it
  # can only grade what it can resolve: it never grades text over a gradient,
  # and it only ever sees the states a fixture happens to render. These are the
  # pairs whose ratio is load-bearing and whose margin is thin enough that a
  # palette nudge would silently land under AA — measured here from the token
  # values themselves, so the failure is a unit test rather than a rendering
  # nobody looked at. Ratios are WCAG 2.x relative luminance.
  #
  # `.decision-revision` washes --super-soft over --surface, so the ink inside
  # it is graded at the tinted end of that gradient — the end axe cannot see,
  # and the end that caught --attention-ink at 4.16:1.
  @aa_text 4.5
  @aa_non_text 3.0

  test "the contrast-critical token pairs still clear WCAG AA" do
    dark = declarations(css_rule(":root"))
    light = declarations(css_rule(~s(html[data-theme="light"])))

    for {theme, tokens} <- [dark: dark, light: light] do
      surface = tokens["--surface"]
      panel = blend(tokens["--super-soft"], surface)

      pairs = [
        {"button ink on its fill", tokens["--on-accent"], tokens["--accent-strong"], @aa_text},
        {"danger ink on its fill", tokens["--on-blocking"], tokens["--blocking"], @aa_text},
        {"muted on surface", tokens["--muted"], surface, @aa_text},
        {"faint on surface", tokens["--faint"], surface, @aa_text},
        {"muted behind pill-bg", tokens["--muted"], blend(tokens["--pill-bg"], surface), @aa_text},
        {"faint behind pill-bg", tokens["--faint"], blend(tokens["--pill-bg"], surface), @aa_text},
        {"attention ink on a tinted panel", tokens["--attention-ink"], blend(tokens["--attention-soft"], panel), @aa_text},
        {"super ink on a tinted panel", tokens["--super-ink"], blend(tokens["--super-soft"], panel), @aa_text},
        # Non-text: the filled button's own edge against the page behind it.
        {"button fill against surface", tokens["--accent-strong"], surface, @aa_non_text}
      ]

      for {label, fg, bg, minimum} <- pairs do
        ratio = contrast(fg, bg)

        assert ratio >= minimum,
               "#{theme} #{label}: #{show(fg)} on #{show(bg)} is " <>
                 "#{Float.round(ratio, 2)}:1, needs #{minimum}:1"
      end
    end
  end

  # A composited backdrop has no CSS spelling, so name it by its channels.
  defp show(color) when is_list(color), do: "rgb(" <> Enum.map_join(color, ", ", &round/1) <> ")"
  defp show(color), do: color

  # Composite `rgba(r, g, b, a)` (or an opaque hex) over an opaque backdrop.
  defp blend(color, backdrop) do
    case Regex.run(~r{rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:[,\s/]+([\d.]+))?\s*\)}, color) do
      [_full, r, g, b] -> blend_channels([to_f(r), to_f(g), to_f(b)], 1.0, rgb(backdrop))
      [_full, r, g, b, a] -> blend_channels([to_f(r), to_f(g), to_f(b)], to_f(a), rgb(backdrop))
      nil -> rgb(color)
    end
  end

  defp blend_channels(fg, alpha, bg) do
    Enum.zip_with(fg, bg, fn f, b -> f * alpha + b * (1 - alpha) end)
  end

  defp to_f(value) do
    {number, _rest} = Float.parse(value)
    number
  end

  defp contrast(fg, bg) do
    [l1, l2] = Enum.map([fg, bg], &luminance/1) |> Enum.sort(:desc)
    (l1 + 0.05) / (l2 + 0.05)
  end

  defp luminance(color) do
    [r, g, b] =
      color
      |> rgb()
      |> Enum.map(fn channel ->
        srgb = channel / 255

        if srgb <= 0.03928, do: srgb / 12.92, else: :math.pow((srgb + 0.055) / 1.055, 2.4)
      end)

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  defp rgb(channels) when is_list(channels), do: channels

  defp rgb("#" <> hex) do
    hex = if String.length(hex) == 3, do: hex |> String.graphemes() |> Enum.map_join(&(&1 <> &1)), else: hex

    hex |> String.to_charlist() |> Enum.chunk_every(2) |> Enum.map(&List.to_integer(&1, 16))
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

  # Anchored on a line start so a descendant rule (`.decision-follow-up .btn {`)
  # can never be mistaken for the base rule it contains as a substring.
  defp css_rule(selector) do
    css = File.read!(@css)
    [_before, rest] = String.split(css, "\n" <> selector <> " {", parts: 2)
    [body, _after] = String.split(rest, "}", parts: 2)
    body
  end
end
