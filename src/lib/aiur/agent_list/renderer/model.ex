defmodule Aiur.AgentList.Renderer.Model do
  @moduledoc """
  Renders model names, model widths, and model colors for agent rows.
  """

  alias Aiur.AgentList.Renderer.{Style, Text}

  # Floor width for the MODEL column: holds the longest base name
  # ("Sonnet" = 6). The column reserves this much when shown and expands
  # to a model's full version string only into spare width (see
  # compute_layout/2). Like PROGRESS, the whole column drops at extreme
  # narrowness — but only after TITLE/LATEST are already at their minimums.
  @model_base_width 6

  # Per-model text colors for the MODEL column, mirroring the website's
  # `.ag-opus` / `.ag-sonnet` / `.ag-codex` classes in
  # `website/src/styles.css`. Keep these hexes in sync with that file:
  #   opus   → #c69bff  (light theme #8a4fd0)
  #   sonnet → #59b0ff  (light theme #1f6fd6)
  #   codex  → #3fb950  (light theme #1f9d4d)
  # 24-bit escapes below match the dark-theme hexes exactly; terminals
  # without truecolor fall back to the nearest ANSI color (magenta/blue/
  # green). The light-theme hexes are recorded here for parity but the TUI
  # renders against an arbitrary terminal background, so it uses the
  # dark-theme values as the canonical mapping.
  @model_truecolor %{opus: "\e[38;2;198;155;255m", sonnet: "\e[38;2;89;176;255m", codex: "\e[38;2;63;185;80m"}
  @model_ansi %{opus: Style.magenta(), sonnet: Style.blue(), codex: Style.green()}
  def engine_word(summary) do
    case Map.get(summary, :backend) do
      backend when is_binary(backend) -> backend |> String.split("-") |> List.first()
      _ -> nil
    end
  end

  # ---------- model column ---------------------------------------------------

  # Iodata for the MODEL column cell: per-model color + base-or-version text
  # + reset + the trailing separator space. `[]` when the column is dropped
  # (model_width 0). The version suffix shows only when the column has been
  # expanded into spare width (model_width > the base floor); otherwise the
  # base name is the floor. Queued / backend-less rows render a dim `–`.
  def model_cell_block(summary, layout) do
    width = layout.model_width

    if width <= 0 do
      []
    else
      family = model_family(summary)
      text = model_text(summary, family, width)
      padded = Text.cell(text, width)

      case model_color(family, Map.get(layout, :truecolor?, true)) do
        # Families with no website color: dim the queued/unknown `–`
        # placeholder (family nil); leave a generic claude/haiku name in the
        # default foreground.
        nil when is_nil(family) -> [Style.dim(), padded, Style.reset(), " "]
        nil -> [padded, " "]
        color -> [color, padded, Style.reset(), " "]
      end
    end
  end

  # Display text for one row's model cell at the resolved column width. Base
  # name is the floor; when the column is wide enough to have been expanded
  # (width past the base floor) the full version string is preferred, falling
  # back to the base name for unpinned models. A row with no resolvable model
  # (queued / no backend) shows a dim en-dash placeholder.
  def model_text(summary, family, width) do
    case model_base(family) do
      "" ->
        "–"

      base ->
        if width > @model_base_width do
          model_full_name(family, Map.get(summary, :model)) || base
        else
          base
        end
    end
  end

  # Natural full width a row wants in the MODEL column: the full version
  # string when a model is pinned, else the base name's length (0 when the
  # row has no resolvable model). compute_layout/2 takes the max across rows.
  def model_natural_width(summary) do
    family = model_family(summary)

    case model_full_name(family, Map.get(summary, :model)) do
      nil -> String.length(model_base(family))
      full -> String.length(full)
    end
  end

  # Website model family driving color + base name. The pinned variant is the
  # most specific signal (opus/sonnet/haiku for claude, gpt for codex); when
  # absent we fall back to the backend family (`codex`, or a generic `claude`
  # with no opus/sonnet pin). `nil` for queued / backend-less rows.
  def model_family(summary) do
    case Map.get(summary, :model) do
      "opus" <> _ -> :opus
      "sonnet" <> _ -> :sonnet
      "haiku" <> _ -> :haiku
      "gpt" <> _ -> :codex
      _ -> family_from_backend(summary)
    end
  end

  def family_from_backend(summary) do
    case engine_word(summary) do
      "codex" -> :codex
      "claude" -> :claude
      _ -> nil
    end
  end

  def model_base(:opus), do: "Opus"
  def model_base(:sonnet), do: "Sonnet"
  def model_base(:haiku), do: "Haiku"
  def model_base(:codex), do: "Codex"
  def model_base(:claude), do: "Claude"
  def model_base(_), do: ""

  # Full human-readable version string, or nil when no version is pinned.
  #   {:opus, "opus-4-8"}    -> "Claude Opus 4.8"
  #   {:sonnet, "sonnet-4-6"}-> "Claude Sonnet 4.6"
  #   {:codex, "gpt-5.5"}    -> "Codex GPT-5.5"
  def model_full_name(:codex, model) when is_binary(model) do
    "Codex " <> String.replace_prefix(model, "gpt", "GPT")
  end

  def model_full_name(family, model) when family in [:opus, :sonnet, :haiku] and is_binary(model) do
    case String.split(model, "-", parts: 2) do
      [_family] -> "Claude " <> model_base(family)
      [_family, version] -> "Claude " <> model_base(family) <> " " <> String.replace(version, "-", ".")
    end
  end

  def model_full_name(_family, _model), do: nil

  # 24-bit truecolor escape (preferred) or nearest ANSI fallback for a
  # model family. `nil` for families with no website color (haiku, generic
  # claude, queued) — those render uncolored.
  def model_color(family, true), do: Map.get(@model_truecolor, family)
  def model_color(family, _falsey), do: Map.get(@model_ansi, family)

  @spec base_width() :: pos_integer()
  def base_width, do: @model_base_width
end
