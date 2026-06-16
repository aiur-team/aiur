defmodule Aiur.Init.Prompt do
  @moduledoc """
  Synchronous raw-mode prompt components for the `aiur init` wizard:

    * `select/4` — single-select radio (↑/↓ to move, Enter to choose)
    * `multiselect/4` — multi-select (↑/↓ to move, Space to toggle, Enter to confirm)
    * `input/3` — single-line text input with an editable pre-filled default

  These reuse the same raw-key stack as `Aiur.AgentList.Input`: put the
  controlling terminal in raw mode via `Aiur.Os.stty/1`, read one byte at a
  time, and parse CSI arrow sequences. Unlike that module (a long-lived
  GenServer feeding the TUI), these are blocking calls that return the chosen
  value, so they suit a one-shot wizard.

  Test seams (mirroring `AgentList.Input`'s `:input_fun` / `:skip_raw_mode`):

    * `:reader` — 0-arity fun returning the next byte as a 1-byte binary or
      `:eof`. Defaults to a blocking `IO.binread(:stdio, 1)`.
    * `:writer` — 1-arity fun for rendering output. Defaults to `IO.write/1`.
    * `:raw?` — whether to toggle termios via `stty`. Defaults to `true`;
      tests pass `false` to drive the key loop without a real terminal.

  On a real terminal where `stty` is unavailable (non-TTY / pipe), the prompt
  degrades to the supplied default rather than hanging or crashing.
  """

  alias Aiur.Os

  @type option :: String.t()

  @cursor "❯"
  @checked "◉"
  @unchecked "○"

  @spec select(String.t(), [option()], option(), keyword()) :: option()
  def select(label, [_ | _] = options, default, opts \\ []) do
    render = Keyword.get(opts, :render, &to_string/1)
    writer = writer(opts)

    with_terminal(default, opts, fn reader ->
      writer.([label, "\n"])
      draw_options(writer, options, cursor_index(options, default), render)
      select_loop(reader, writer, options, cursor_index(options, default), render)
    end)
  end

  @spec multiselect(String.t(), [option()], [option()], keyword()) :: [option()]
  def multiselect(label, [_ | _] = options, defaults, opts \\ []) do
    render = Keyword.get(opts, :render, &to_string/1)
    writer = writer(opts)
    selected = MapSet.new(Enum.filter(options, &(&1 in defaults)))

    with_terminal(defaults, opts, fn reader ->
      writer.([label, " (Space toggles, Enter confirms)\n"])
      draw_multi(writer, options, 0, selected, render)
      multi_loop(reader, writer, options, 0, selected, render)
    end)
  end

  @spec input(String.t(), String.t() | nil, keyword()) :: String.t()
  def input(label, default, opts \\ []) do
    writer = writer(opts)
    buffer = to_string(default || "")

    with_terminal(buffer, opts, fn reader ->
      prefix = input_header(writer, label, Keyword.get(opts, :hint))
      draw_input(writer, prefix, buffer)
      input_loop(reader, writer, prefix, buffer)
    end)
  end

  # --- selection loops ---

  defp select_loop(reader, writer, options, cursor, render) do
    case read_key(reader) do
      :up ->
        cursor = max(0, cursor - 1)
        redraw_options(writer, options, cursor, render)
        select_loop(reader, writer, options, cursor, render)

      :down ->
        cursor = min(length(options) - 1, cursor + 1)
        redraw_options(writer, options, cursor, render)
        select_loop(reader, writer, options, cursor, render)

      key when key in [:enter, :eof] ->
        writer.("\n")
        Enum.at(options, cursor)

      _other ->
        select_loop(reader, writer, options, cursor, render)
    end
  end

  defp multi_loop(reader, writer, options, cursor, selected, render) do
    case read_key(reader) do
      :up ->
        cursor = max(0, cursor - 1)
        redraw_multi(writer, options, cursor, selected, render)
        multi_loop(reader, writer, options, cursor, selected, render)

      :down ->
        cursor = min(length(options) - 1, cursor + 1)
        redraw_multi(writer, options, cursor, selected, render)
        multi_loop(reader, writer, options, cursor, selected, render)

      :space ->
        selected = toggle(selected, Enum.at(options, cursor))
        redraw_multi(writer, options, cursor, selected, render)
        multi_loop(reader, writer, options, cursor, selected, render)

      key when key in [:enter, :eof] ->
        writer.("\n")
        Enum.filter(options, &MapSet.member?(selected, &1))

      _other ->
        multi_loop(reader, writer, options, cursor, selected, render)
    end
  end

  defp input_loop(reader, writer, prefix, buffer) do
    case read_key(reader) do
      key when key in [:enter, :eof] ->
        writer.("\n")
        buffer

      :backspace ->
        buffer = String.slice(buffer, 0..-2//1)
        draw_input(writer, prefix, buffer)
        input_loop(reader, writer, prefix, buffer)

      {:char, <<byte>>} when byte >= 0x20 and byte != 0x7F ->
        buffer = buffer <> <<byte>>
        draw_input(writer, prefix, buffer)
        input_loop(reader, writer, prefix, buffer)

      _other ->
        input_loop(reader, writer, prefix, buffer)
    end
  end

  # --- rendering ---

  defp draw_options(writer, options, cursor, render) do
    writer.(option_lines(options, cursor, render))
  end

  defp redraw_options(writer, options, cursor, render) do
    writer.(["\e[#{length(options)}A", option_lines(options, cursor, render)])
  end

  defp option_lines(options, cursor, render) do
    options
    |> Enum.with_index()
    |> Enum.map_join(fn {opt, i} ->
      marker = if i == cursor, do: @cursor, else: " "
      ["\e[2K", marker, " ", render.(opt), "\n"]
    end)
  end

  defp draw_multi(writer, options, cursor, selected, render) do
    writer.(multi_lines(options, cursor, selected, render))
  end

  defp redraw_multi(writer, options, cursor, selected, render) do
    writer.(["\e[#{length(options)}A", multi_lines(options, cursor, selected, render)])
  end

  defp multi_lines(options, cursor, selected, render) do
    options
    |> Enum.with_index()
    |> Enum.map_join(fn {opt, i} ->
      marker = if i == cursor, do: @cursor, else: " "
      box = if MapSet.member?(selected, opt), do: @checked, else: @unchecked
      ["\e[2K", marker, " ", box, " ", render.(opt), "\n"]
    end)
  end

  # With a hint, the question and a faint indented hint print on their own
  # lines and the editable field sits below behind a `❯` marker. With no
  # hint, the field stays inline as `label: <value>`.
  defp input_header(_writer, label, hint) when hint in [nil, ""], do: label <> ":"

  defp input_header(writer, label, hint) do
    writer.([label, "\n", IO.ANSI.format([:faint, "  " <> hint]), "\n"])
    @cursor
  end

  defp draw_input(writer, prefix, buffer) do
    writer.(["\r\e[2K", prefix, " ", buffer])
  end

  # --- key reading ---

  defp read_key(reader) do
    case reader.() do
      :eof -> :eof
      "\e" -> read_escape(reader)
      "\r" -> :enter
      "\n" -> :enter
      " " -> :space
      <<127>> -> :backspace
      <<8>> -> :backspace
      other -> {:char, other}
    end
  end

  defp read_escape(reader) do
    case reader.() do
      "[" -> read_csi(reader)
      _ -> :other
    end
  end

  defp read_csi(reader) do
    case reader.() do
      "A" -> :up
      "B" -> :down
      "C" -> :right
      "D" -> :left
      _ -> :other
    end
  end

  # --- terminal lifecycle ---

  # Runs `fun.(reader)` with the terminal in raw mode, always restoring it.
  # When `stty` is unavailable (no TTY), degrades to `default` instead of
  # blocking on reads that can never deliver arrow keys.
  defp with_terminal(default, opts, fun) do
    reader = reader(opts)
    stty = stty_fun(opts)

    case enter_raw(Keyword.get(opts, :raw?, true), stty) do
      :skip ->
        fun.(reader)

      :raw ->
        try do
          fun.(reader)
        after
          restore_terminal(stty)
        end

      :degrade ->
        default
    end
  end

  defp enter_raw(false, _stty), do: :skip

  defp enter_raw(true, stty) do
    case stty.(["-icanon", "-echo", "min", "1", "time", "0"]) do
      :ok ->
        IO.write("\e[?25l")
        :raw

      _ ->
        :degrade
    end
  rescue
    _ -> :degrade
  end

  defp restore_terminal(stty) do
    IO.write("\e[?25h")
    stty.(["sane"])
  rescue
    _ -> :ok
  end

  # --- helpers ---

  defp reader(opts), do: Keyword.get(opts, :reader, fn -> IO.binread(:stdio, 1) end)
  defp writer(opts), do: Keyword.get(opts, :writer, &IO.write/1)
  defp stty_fun(opts), do: Keyword.get(opts, :stty, &Os.stty/1)

  defp cursor_index(options, default) do
    case Enum.find_index(options, &(&1 == default)) do
      nil -> 0
      i -> i
    end
  end

  defp toggle(set, value) do
    if MapSet.member?(set, value), do: MapSet.delete(set, value), else: MapSet.put(set, value)
  end
end
