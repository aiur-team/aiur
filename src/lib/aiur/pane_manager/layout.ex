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

  In `:horizontal` orientation (the default, suited to wide monitors):

    * top row holds `[agent_list, slot 1, slot 2, ..., slot (columns - 1)]`
    * bottom row holds `[slot columns, ..., slot (2*columns - 1)]`

  In `:vertical` orientation (rotated 90° for phones / portrait monitors):

    * left column holds `[agent_list, slot 1, ..., slot (columns - 1)]`
      stacked top-to-bottom
    * right column holds `[slot columns, ..., slot (2*columns - 1)]`
      stacked top-to-bottom

  Slot numbering and capacity are identical in both orientations — only
  the visual axis differs. Empty slots collapse: the row/column's
  remaining panes split the available extent evenly. An entirely empty
  secondary group makes the primary group span the full dimension.

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

  require Logger

  alias Aiur.PaneManager.State
  alias Aiur.Tmux

  @type pane_id :: String.t()

  @type orientation :: :horizontal | :vertical

  @spec apply(Aiur.PaneManager.State.t()) :: :ok | {:error, term()}
  def apply(state) do
    with {:ok, {w, h}} <- Tmux.window_size(state.tmux, state.agent_list_pane),
         layout_string =
           build(
             w,
             h,
             state.max_vertical_panes,
             state.agent_list_pane,
             State.visible_panes_packed(state),
             state.orientation
           ),
         _ = log_layout_apply(state, w, h, layout_string),
         :ok <- Tmux.select_layout(state.tmux, state.window_target, layout_string) do
      :ok
    else
      {:error, reason} = err ->
        Logger.warning("PaneManager: layout apply failed: #{inspect(reason)}")
        err
    end
  end

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
    * `orientation` — `:horizontal` (default) lays the grid out as two
      rows; `:vertical` rotates it 90° into two columns, suited to
      portrait monitors and phone clients.
  """
  @spec build(
          pos_integer(),
          pos_integer(),
          pos_integer(),
          pane_id(),
          [pane_id() | nil],
          orientation()
        ) :: String.t()
  def build(width, height, columns, agent_list_pane, slot_panes, orientation \\ :horizontal)
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 and
             is_integer(columns) and columns > 0 and is_binary(agent_list_pane) and
             is_list(slot_panes) and orientation in [:horizontal, :vertical] do
    primary_capacity = columns - 1
    primary_panes = [agent_list_pane | Enum.take(slot_panes, primary_capacity)]
    secondary_panes = Enum.drop(slot_panes, primary_capacity)

    primary_alive = Enum.reject(primary_panes, &is_nil/1)
    secondary_alive = Enum.reject(secondary_panes, &is_nil/1)

    body = render_body(orientation, width, height, primary_alive, secondary_alive)
    "#{checksum_hex(body)},#{body}"
  end

  defp render_body(:horizontal, width, height, primary_alive, []) do
    render_row(width, height, 0, 0, primary_alive)
  end

  defp render_body(:horizontal, width, height, primary_alive, secondary_alive) do
    {top_h, bottom_h} = split_dim(height)
    top_row = render_row(width, top_h, 0, 0, primary_alive)
    bottom_row = render_row(width, bottom_h, 0, top_h + 1, secondary_alive)
    "#{width}x#{height},0,0[#{top_row},#{bottom_row}]"
  end

  defp render_body(:vertical, width, height, primary_alive, []) do
    render_column(width, height, 0, 0, primary_alive)
  end

  defp render_body(:vertical, width, height, primary_alive, secondary_alive) do
    {left_w, right_w} = split_dim(width)
    left_col = render_column(left_w, height, 0, 0, primary_alive)
    right_col = render_column(right_w, height, left_w + 1, 0, secondary_alive)
    "#{width}x#{height},0,0{#{left_col},#{right_col}}"
  end

  # Single-pane row: leaf cell, no braces.
  defp render_row(w, h, x, y, [single]) do
    "#{w}x#{h},#{x},#{y},#{pane_numeric(single)}"
  end

  # Multi-pane row: horizontal arrangement, panes side by side.
  defp render_row(w, h, x, y, panes) do
    cells = even_dims(panes, w)

    rendered =
      cells
      |> Enum.map_reduce(0, fn {pane, cell_w}, x_offset ->
        cell = "#{cell_w}x#{h},#{x + x_offset},#{y},#{pane_numeric(pane)}"
        {cell, x_offset + cell_w + 1}
      end)
      |> elem(0)

    "#{w}x#{h},#{x},#{y}{#{Enum.join(rendered, ",")}}"
  end

  # Single-pane column: leaf cell, no brackets.
  defp render_column(w, h, x, y, [single]) do
    "#{w}x#{h},#{x},#{y},#{pane_numeric(single)}"
  end

  # Multi-pane column: vertical stack, panes top-to-bottom.
  defp render_column(w, h, x, y, panes) do
    cells = even_dims(panes, h)

    rendered =
      cells
      |> Enum.map_reduce(0, fn {pane, cell_h}, y_offset ->
        cell = "#{w}x#{cell_h},#{x},#{y + y_offset},#{pane_numeric(pane)}"
        {cell, y_offset + cell_h + 1}
      end)
      |> elem(0)

    "#{w}x#{h},#{x},#{y}[#{Enum.join(rendered, ",")}]"
  end

  # tmux's pane-divider math: N panes in extent E consume (N - 1) cells
  # of dividers, leaving (E - N + 1) for the panes themselves. The
  # remainder after an even split goes to the leftmost / topmost panes
  # (matches `select-layout even-*`'s rounding).
  defp even_dims(panes, total) do
    n = length(panes)
    inner = total - (n - 1)
    base = div(inner, n)
    remainder = rem(inner, n)

    panes
    |> Enum.with_index()
    |> Enum.map(fn {pane, idx} ->
      dim = base + if idx < remainder, do: 1, else: 0
      {pane, dim}
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

  defp log_layout_apply(state, w, h, layout_string) do
    if debug_mode?() do
      slot_panes_summary =
        state.slot_panes
        |> Enum.sort_by(fn {slot, _} -> slot end)
        |> Enum.map_join(",", fn {slot, pane} -> "#{slot}=>#{pane || "_"}" end)

      Logger.info("aiur_tmux_layout window=#{w}x#{h} slot_panes=#{slot_panes_summary} agent_list=#{state.agent_list_pane} layout=#{inspect(layout_string)}")
    end

    :ok
  end

  defp debug_mode? do
    case System.get_env("AIUR_DEBUG") do
      value when is_binary(value) ->
        String.downcase(String.trim(value)) in ["1", "true", "yes"]

      _ ->
        false
    end
  end
end
