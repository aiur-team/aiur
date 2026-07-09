defmodule Aiur.AgentList.Renderer.Text do
  @moduledoc """
  Visual-width, ANSI-safe text helpers for the agent-list renderer.
  """

  alias Aiur.AgentList.Renderer.Style

  @spec cell(term(), non_neg_integer()) :: String.t()
  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  @spec pad_with_ansi(iodata(), iodata(), non_neg_integer(), iodata()) :: iodata()
  @spec padding_for(String.t(), non_neg_integer()) :: iodata()
  @spec visual_width(String.t()) :: non_neg_integer()
  @spec grapheme_width(String.t()) :: non_neg_integer()
  @spec codepoint_width(integer()) :: non_neg_integer()
  @spec truncate_visual(String.t(), integer()) :: String.t()
  @spec take_visible(String.t(), non_neg_integer(), iodata(), non_neg_integer(), boolean()) ::
          {iodata(), non_neg_integer(), boolean()}
  @spec take_grapheme(String.t(), non_neg_integer(), iodata(), non_neg_integer(), boolean()) ::
          {iodata(), non_neg_integer(), boolean()}
  @spec split_escape(String.t()) :: {:osc_close | :osc_open | :csi, String.t(), String.t()} | :none
  @spec split_csi(String.t()) :: {:csi, String.t(), String.t()} | :none
  @spec osc_kind(String.t()) :: :osc_close | :osc_open
  @spec drop_prefix(String.t(), String.t()) :: String.t()
  @spec clip_and_pad(String.t(), non_neg_integer()) :: iodata()
  @spec strip_csi(String.t()) :: String.t()
  @spec strip_ansi(String.t()) :: String.t()
  @spec eol() :: iodata()
  @spec emoji_cell(String.t(), non_neg_integer()) :: String.t()

  def cell(value, width) do
    str =
      value
      |> to_string()
      |> String.replace("\n", " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> truncate(width)

    String.pad_trailing(str, width)
  end

  def truncate(value, width) do
    cond do
      String.length(value) <= width -> value
      width <= 3 -> String.slice(value, 0, width)
      true -> String.slice(value, 0, width - 1) <> "…"
    end
  end

  def pad_with_ansi(ansi, text, inner_width, right_border \\ "│") do
    # clip_and_pad fills to inner_width - 1 visual cols and then appends
    # `right_border` so every row carries a closing vertical bar on the
    # right side (matching the leading `│` on the left). Specific row
    # types pass `╮` / `╯` / `┤` for corner / divider variants.
    [
      ansi,
      clip_and_pad(text, max(inner_width - 1, 0)),
      right_border,
      Style.reset()
    ]
  end

  def padding_for(text, inner_width) do
    # Use visual_width, not String.length: emoji + CJK glyphs count as
    # one grapheme but render as TWO terminal columns. Padding by
    # grapheme count over-pads, the line exceeds inner_width, and the
    # terminal wraps — which throws off our line-count bookkeeping and
    # eventually scrolls the top of the pane off-screen.
    #
    # Reserve the last visual column for the right `│` border so each
    # metadata row closes cleanly. The iodata returned here ends with
    # the border glyph; callers don't need to append it themselves.
    visible = visual_width(strip_ansi(text))
    pad = String.duplicate(" ", max(inner_width - visible - 1, 0))
    [pad, Style.gray(), "│", Style.reset()]
  end

  def visual_width(text) when is_binary(text) do
    text
    |> strip_ansi()
    |> String.graphemes()
    |> Enum.reduce(0, fn g, acc -> acc + grapheme_width(g) end)
  end

  def grapheme_width(g) do
    case String.to_charlist(g) do
      [cp | _] -> codepoint_width(cp)
      [] -> 0
    end
  end

  def codepoint_width(cp) when cp < 0x80, do: 1
  # Zero-width: combining marks, ZWJ, variation selectors. Keep these
  # at 0 so emoji presentation modifiers don't double-count.
  def codepoint_width(cp) when cp >= 0x300 and cp <= 0x36F, do: 0
  def codepoint_width(0x200B), do: 0
  def codepoint_width(0x200C), do: 0
  def codepoint_width(0x200D), do: 0
  def codepoint_width(0xFE0E), do: 0
  def codepoint_width(0xFE0F), do: 0
  # East-Asian Wide + Fullwidth ranges.
  def codepoint_width(cp) when cp >= 0x1100 and cp <= 0x115F, do: 2
  def codepoint_width(cp) when cp >= 0x2E80 and cp <= 0x303E, do: 2
  def codepoint_width(cp) when cp >= 0x3041 and cp <= 0x33FF, do: 2
  def codepoint_width(cp) when cp >= 0x3400 and cp <= 0x4DBF, do: 2
  def codepoint_width(cp) when cp >= 0x4E00 and cp <= 0x9FFF, do: 2
  def codepoint_width(cp) when cp >= 0xA000 and cp <= 0xA4CF, do: 2
  def codepoint_width(cp) when cp >= 0xAC00 and cp <= 0xD7A3, do: 2
  def codepoint_width(cp) when cp >= 0xF900 and cp <= 0xFAFF, do: 2
  def codepoint_width(cp) when cp >= 0xFE30 and cp <= 0xFE4F, do: 2
  def codepoint_width(cp) when cp >= 0xFF00 and cp <= 0xFF60, do: 2
  def codepoint_width(cp) when cp >= 0xFFE0 and cp <= 0xFFE6, do: 2
  # Selected symbol blocks that terminals render as wide / emoji-style.
  # Many cells in 2600-26FF are 1 col in some terminals but render as
  # 2 in modern emoji fonts — overcount is safer than wrap.
  def codepoint_width(cp) when cp >= 0x2600 and cp <= 0x27BF, do: 2
  def codepoint_width(cp) when cp >= 0x2B00 and cp <= 0x2BFF, do: 2
  def codepoint_width(cp) when cp >= 0x1F000, do: 2
  # Everything else (Latin-1 supplement, arrows, box drawing, …) is 1.
  def codepoint_width(_cp), do: 1

  @csi_re ~r/^\e\[[0-9;?]*[A-Za-z]/
  # Matches both OSC 8 forms (open carries a URL, close has an empty URL),
  # terminated by ST (`\e\\`) or BEL (`\a`).
  @osc8_re ~r/^\e\]8;;[^\e\a]*(?:\e\\|\a)/
  @osc8_close_re ~r/^\e\]8;;(?:\e\\|\a)/

  def truncate_visual(_text, limit) when limit <= 0, do: ""

  def truncate_visual(text, limit) do
    {acc, _used, open_link?} = take_visible(text, limit, [], 0, false)
    result = IO.iodata_to_binary(acc)
    if open_link?, do: result <> "\e]8;;\e\\", else: result
  end

  def take_visible("", _limit, acc, used, open?), do: {acc, used, open?}

  def take_visible(text, limit, acc, used, open?) do
    case split_escape(text) do
      {:osc_close, seq, rest} -> take_visible(rest, limit, [acc, seq], used, false)
      {:osc_open, seq, rest} -> take_visible(rest, limit, [acc, seq], used, true)
      {:csi, seq, rest} -> take_visible(rest, limit, [acc, seq], used, open?)
      :none -> take_grapheme(text, limit, acc, used, open?)
    end
  end

  def take_grapheme(text, limit, acc, used, open?) do
    {g, rest} = String.next_grapheme(text)
    w = grapheme_width(g)

    if used + w > limit do
      {acc, used, open?}
    else
      take_visible(rest, limit, [acc, g], used + w, open?)
    end
  end

  def split_escape(text) do
    case Regex.run(@osc8_re, text, return: :binary) do
      [seq | _] -> {osc_kind(seq), seq, drop_prefix(text, seq)}
      nil -> split_csi(text)
    end
  end

  def split_csi(text) do
    case Regex.run(@csi_re, text, return: :binary) do
      [seq | _] -> {:csi, seq, drop_prefix(text, seq)}
      nil -> :none
    end
  end

  def osc_kind(seq) do
    if Regex.match?(@osc8_close_re, seq), do: :osc_close, else: :osc_open
  end

  def drop_prefix(text, prefix) do
    plen = byte_size(prefix)
    binary_part(text, plen, byte_size(text) - plen)
  end

  def clip_and_pad(text, inner_width) do
    if visual_width(text) <= inner_width do
      [text, String.duplicate(" ", max(inner_width - visual_width(text), 0))]
    else
      trimmed = truncate_visual(text, max(inner_width - 1, 0)) <> "…"
      [trimmed, String.duplicate(" ", max(inner_width - visual_width(trimmed), 0))]
    end
  end

  def strip_csi(text) do
    Regex.replace(~r/\e\[[0-9;?]*[A-Za-z]/, text, "")
  end

  def strip_ansi(text) do
    text
    # CSI (color/cursor) sequences: `\e[...m`, `\e[2J`, etc.
    |> strip_csi()
    # OSC 8 hyperlinks: `\e]8;;<url>\e\\<text>\e]8;;\e\\` (or BEL-terminated).
    # The text between the brackets is the visible part — we keep
    # everything between the ST and the closing OSC.
    |> then(&Regex.replace(~r/\e\]8;;[^\e\a]*(\e\\|\a)/, &1, ""))
  end

  def eol, do: ["\e[K", "\r\n"]

  def emoji_cell("", width) do
    # Reserved-but-empty cell: pad to the full visual width.
    String.duplicate(" ", max(width, 0))
  end

  def emoji_cell(glyph, width) do
    # The leading grapheme is a 2-terminal-column emoji; everything
    # after (digits, suffix) is 1 column per char. `❗3` reads as
    # visual_width = 2 + 1 = 3; `❗9+` reads as 2 + 2 = 4. Pad with
    # the remainder so the cell is exactly `width` columns wide.
    visual =
      case String.next_grapheme(glyph) do
        {_first, rest} -> 2 + String.length(rest)
        nil -> 0
      end

    pad = String.duplicate(" ", max(width - visual, 0))
    glyph <> pad
  end
end
