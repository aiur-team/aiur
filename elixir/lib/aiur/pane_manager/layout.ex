defmodule Aiur.PaneManager.Layout do
  @moduledoc """
  Builds tmux window-layout strings positioning the agent-list pane and
  conversation slot panes into the deterministic grid issue #34 specifies.

  Applied via `tmux select-layout <string>` after every slot change so the
  layout is independent of the order tmux's `split-window` chose to place
  new panes — and immune to any `after-split-window` hooks that might
  otherwise re-shuffle things.

  ## Layout schema

  Given `max_vertical_panes = columns`:

    * top row holds `[agent_list, slot 1, slot 2, ..., slot (columns - 1)]`
    * bottom row holds `[slot columns, ..., slot (2*columns - 1)]`

  Empty slots collapse: the row's remaining panes split the row width
  evenly. An entirely empty bottom row makes the top row span full height.

  ## Format

  Returns a string of the form `<csum>,<body>` where `<csum>` is a 4-char
  lowercase hex CRC computed over `<body>` (matching tmux's
  `layout_checksum` in `layout-custom.c`). Cells are `WxH,X,Y,pane_num`
  for a single pane, `WxH,X,Y{...}` for a horizontal arrangement, and
  `WxH,X,Y[...]` for a vertical stack.

  The tmux convention: width counts cells, dividers between siblings
  consume 1 cell each, and positions are absolute within the window.
  """

  import Bitwise

  @type pane_id :: String.t()

  @doc """
  Build the layout string for the current window dimensions and slot
  occupancy.

    * `width`, `height` — window dimensions in cells (from
      `tmux display-message` with the `window_width` / `window_height`
      format variables).
    * `columns` — `max_vertical_panes` from workflow config.
    * `agent_list_pane` — the always-present anchor pane id (`"%N"`).
    * `slot_panes` — list of length `2 * columns - 1`; each entry is the
      pane id occupying that slot or `nil` when the slot is empty. Slot
      numbering matches `PaneManager` (1-indexed in docs, 0-indexed here).
  """
  @spec build(
          pos_integer(),
          pos_integer(),
          pos_integer(),
          pane_id(),
          [pane_id() | nil]
        ) :: String.t()
  def build(width, height, columns, agent_list_pane, slot_panes)
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 and
             is_integer(columns) and columns > 0 and is_binary(agent_list_pane) and
             is_list(slot_panes) do
    top_capacity = columns - 1
    top_row_panes = [agent_list_pane | Enum.take(slot_panes, top_capacity)]
    bottom_row_panes = Enum.drop(slot_panes, top_capacity)

    top_alive = Enum.reject(top_row_panes, &is_nil/1)
    bottom_alive = Enum.reject(bottom_row_panes, &is_nil/1)

    body =
      if bottom_alive == [] do
        render_row(width, height, 0, 0, top_alive)
      else
        {top_h, bottom_h} = split_dim(height)
        top_row = render_row(width, top_h, 0, 0, top_alive)
        bottom_row = render_row(width, bottom_h, 0, top_h + 1, bottom_alive)
        "#{width}x#{height},0,0[#{top_row},#{bottom_row}]"
      end

    "#{checksum_hex(body)},#{body}"
  end

  # Single-pane row: leaf cell, no braces.
  defp render_row(w, h, x, y, [single]) do
    "#{w}x#{h},#{x},#{y},#{pane_numeric(single)}"
  end

  # Multi-pane row: horizontal arrangement, panes side by side.
  defp render_row(w, h, x, y, panes) do
    cells = cells_with_widths(panes, w)

    rendered =
      cells
      |> Enum.map_reduce(0, fn {pane, cell_w}, x_offset ->
        cell = "#{cell_w}x#{h},#{x + x_offset},#{y},#{pane_numeric(pane)}"
        {cell, x_offset + cell_w + 1}
      end)
      |> elem(0)

    "#{w}x#{h},#{x},#{y}{#{Enum.join(rendered, ",")}}"
  end

  # tmux's pane-divider math: N panes in width W consume (N - 1) cells of
  # dividers, leaving (W - N + 1) for the panes themselves. The remainder
  # after an even split goes to the leftmost / topmost panes (matches
  # `select-layout even-horizontal`'s rounding).
  defp cells_with_widths(panes, total_w) do
    n = length(panes)
    inner = total_w - (n - 1)
    base = div(inner, n)
    remainder = rem(inner, n)

    panes
    |> Enum.with_index()
    |> Enum.map(fn {pane, idx} ->
      width = base + if idx < remainder, do: 1, else: 0
      {pane, width}
    end)
  end

  defp split_dim(dim) do
    inner = dim - 1
    base = div(inner, 2)
    remainder = rem(inner, 2)
    {base + remainder, base}
  end

  defp pane_numeric("%" <> rest), do: rest
  defp pane_numeric(id) when is_binary(id), do: id

  # 16-bit checksum matching tmux's `layout-custom.c#layout_checksum`:
  # rolling right-rotate-by-1 accumulator over the layout body bytes.
  @doc false
  @spec checksum(String.t()) :: non_neg_integer()
  def checksum(body) when is_binary(body) do
    body
    |> :binary.bin_to_list()
    |> Enum.reduce(0, fn ch, csum ->
      shifted = bsr(csum, 1) + bsl(band(csum, 1), 15)
      band(shifted + ch, 0xFFFF)
    end)
  end

  defp checksum_hex(body) do
    body
    |> checksum()
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(4, "0")
  end
end
