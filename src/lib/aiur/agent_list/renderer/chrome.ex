defmodule Aiur.AgentList.Renderer.Chrome do
  @moduledoc """
  Renders bordered chrome, metadata, and footer keybind rows.
  It owns only the visual frame furniture around the agent table.
  """

  alias Aiur.AgentList.Renderer.{Style, Text}

  # ---------- header / metadata ---------------------------------------------

  @spec title_row(term()) :: term()
  def title_row(inner_width) do
    title = "╭─ AIUR"
    title_visual = Text.visual_width(title)

    # `╮` rounded corner reserved at the far right; padding fills the gap
    # between the AIUR title and the corner.
    pad_count = max(inner_width - title_visual - 1, 1)
    pad = String.duplicate(" ", pad_count)

    [Style.bold(), title, Style.reset(), pad, Style.gray(), "╮", Style.reset()]
  end

  @spec metadata_rows(term(), term()) :: term()
  def metadata_rows(state, inner_width) do
    [
      agents_row(
        Map.get(state, :agent_kind),
        Map.get(state, :agent_count),
        Map.get(state, :max_agents),
        Map.get(state, :selection_focus) == :max_agents,
        Map.get(state, :max_agents_alert?) == true,
        inner_width
      ),
      Text.eol(),
      project_row(Map.get(state, :project_label), inner_width),
      Text.eol(),
      dashboard_row(Map.get(state, :dashboard_url), inner_width),
      Text.eol(),
      usage_row(Map.get(state, :provider_usage), inner_width),
      Text.eol()
    ]
  end

  @doc """
  Limit headroom for each provider, as a bar plus the age of the observation.

  Meters are observed from live agent sessions, so a bar with no age cannot be
  told apart from a current one. A provider that has never been observed reads
  as `n/a` and draws no bar — an empty bar would read as "0% consumed".
  """
  @spec usage_row(term(), term()) :: term()
  def usage_row(usage, inner_width) when is_map(usage) and map_size(usage) > 0 do
    case usage |> Enum.sort_by(fn {provider, _view} -> provider end) |> Enum.map(&usage_segment/1) do
      [] -> metadata_row_iolist("Usage:", "n/a", Style.gray(), inner_width)
      segments -> metadata_row_iolist("Usage:", Enum.join(segments, "  "), Style.cyan(), inner_width)
    end
  end

  def usage_row(_usage, inner_width), do: metadata_row_iolist("Usage:", "n/a", Style.gray(), inner_width)

  # Codex reports a consumed fraction, so it gets a bar. Claude reports only a
  # standing and a reset time — its CLI exposes no utilization at all — so it
  # gets those instead. Rendering an empty bar for Claude would read as "0%
  # consumed", which is a claim the data does not support.
  defp usage_segment({provider, %{state: :observed} = view}) do
    case local_concurrency_summary(view) do
      nil ->
        case usage_percent(view) do
          nil -> "#{provider_abbrev(provider)} #{fact_summary(view)}"
          percent -> "#{provider_abbrev(provider)} #{usage_bar(percent)} #{round(percent)}% #{age_suffix(view[:age_seconds])}"
        end

      summary ->
        "#{provider_abbrev(provider)} #{summary} #{age_suffix(view[:age_seconds])}"
    end
  end

  defp usage_segment({provider, _view}), do: "#{provider_abbrev(provider)} n/a"

  # The worst-consumed rate-limit window is the one that will stop work first,
  # so it is the number worth the header's single line.
  defp usage_percent(%{windows: windows}) when is_map(windows) do
    windows
    |> Map.values()
    |> Enum.filter(&(Map.get(&1, :kind) == :rate_limit))
    |> Enum.map(&Map.get(&1, :used_percent))
    |> Enum.filter(&is_number/1)
    |> case do
      [] -> nil
      percents -> Enum.max(percents)
    end
  end

  defp usage_percent(_view), do: nil

  defp local_concurrency_summary(view) do
    view
    |> Map.get(:windows, %{})
    |> Map.values()
    |> Enum.find(&local_concurrency_window?/1)
    |> case do
      %{used: used, limit: limit} when is_number(used) and is_number(limit) ->
        [credit_fact(view), "#{used}/#{limit} concurrent"]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · ")

      _window ->
        nil
    end
  end

  defp local_concurrency_window?(window) do
    Map.get(window, :name) in [:concurrency, "Local concurrency"]
  end

  # A provider that reports standing without a percentage still has something
  # worth the header's space: whether it is allowed, and when the window resets.
  defp fact_summary(view) do
    windows = view |> Map.get(:windows, %{}) |> Map.values() |> Enum.filter(&(Map.get(&1, :kind) == :rate_limit))

    case Enum.find(windows, &Map.get(&1, :standing)) do
      nil -> credit_summary(view)
      window -> [standing_word(window.standing), reset_suffix(Map.get(window, :resets_at))] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
    end
  end

  defp credit_summary(view) do
    case credit_fact(view) do
      nil -> "n/a"
      fact -> "#{fact} #{age_suffix(view[:age_seconds])}"
    end
  end

  defp credit_fact(view) do
    view
    |> Map.get(:windows, %{})
    |> Map.values()
    |> Enum.find_value(fn
      %{kind: :credit, credits: %{amount: amount}} when is_number(amount) -> "$#{format_amount(amount)} left"
      _window -> nil
    end)
  end

  defp format_amount(amount), do: :erlang.float_to_binary(amount / 1, decimals: 2)

  defp standing_word(:allowed), do: "ok"
  defp standing_word(:allowed_warning), do: "near limit"
  defp standing_word(:rejected), do: "limited"
  defp standing_word(_standing), do: "n/a"

  defp reset_suffix(%DateTime{} = resets_at) do
    case DateTime.diff(resets_at, DateTime.utc_now()) do
      seconds when seconds <= 0 -> nil
      seconds when seconds < 3_600 -> "· resets in #{div(seconds, 60)}m"
      seconds when seconds < 86_400 -> "· resets in #{div(seconds, 3_600)}h"
      # Days once there are any: a weekly window reading "167h" makes the reader
      # divide to learn it is a week away. The header is tight, so hours only.
      seconds -> "· resets in #{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3_600)}h"
    end
  end

  defp reset_suffix(_resets_at), do: nil

  @bar_cells 10

  defp usage_bar(percent) do
    filled = percent |> max(0) |> min(100) |> Kernel./(100) |> Kernel.*(@bar_cells) |> round()
    String.duplicate("█", filled) <> String.duplicate("░", @bar_cells - filled)
  end

  defp age_suffix(nil), do: "(age n/a)"
  defp age_suffix(seconds) when seconds < 60, do: "(#{seconds}s)"
  defp age_suffix(seconds) when seconds < 3_600, do: "(#{div(seconds, 60)}m)"
  defp age_suffix(seconds), do: "(#{div(seconds, 3_600)}h)"

  defp provider_abbrev(:codex), do: "codex"
  defp provider_abbrev(:claude), do: "claude"
  defp provider_abbrev(other), do: to_string(other)

  @spec agents_row(term(), term(), term(), term(), term(), term()) :: term()
  def agents_row(_kind, count, max, focused?, alert?, inner_width)
      when is_integer(count) and is_integer(max) and max > 0 do
    agents_row_iolist(nil, count, max, focused?, alert?, inner_width)
  end

  def agents_row(_kind, count, _max, _focused?, _alert?, inner_width) when is_integer(count) do
    metadata_row_iolist("Agents:", to_string(count), Style.cyan(), inner_width)
  end

  def agents_row(_kind, _count, _max, _focused?, _alert?, inner_width),
    do: metadata_row_iolist("Agents:", "n/a", Style.gray(), inner_width)

  @spec project_row(term(), term()) :: term()
  def project_row(nil, inner_width),
    do: metadata_row_iolist("Project:", "n/a", Style.gray(), inner_width)

  def project_row("", inner_width),
    do: metadata_row_iolist("Project:", "n/a", Style.gray(), inner_width)

  def project_row(label, inner_width),
    do: metadata_row_iolist("Project:", label, Style.cyan(), inner_width)

  @spec dashboard_row(term(), term()) :: term()
  def dashboard_row(nil, inner_width),
    do: metadata_row_iolist("Dashboard:", "n/a", Style.gray(), inner_width)

  def dashboard_row("", inner_width),
    do: metadata_row_iolist("Dashboard:", "n/a", Style.gray(), inner_width)

  def dashboard_row(url, inner_width),
    do: metadata_row_iolist("Dashboard:", url, Style.cyan(), inner_width)

  @spec metadata_row_iolist(term(), term(), term(), term()) :: term()
  def metadata_row_iolist(label, value, value_color, inner_width) do
    prefix = "│ "
    bold_label = Style.bold() <> label <> Style.reset()
    colored_value = value_color <> value <> Style.reset()
    plain = prefix <> label <> " " <> value
    pad = Text.padding_for(plain, inner_width)
    [prefix, bold_label, " ", colored_value, pad]
  end

  @spec agents_row_iolist(term(), term(), term(), term(), term(), term()) :: term()
  def agents_row_iolist(_kind, count, max, focused?, alert?, inner_width) do
    label = "Agents:"
    prefix = "│ "
    bold_label = Style.bold() <> label <> Style.reset()
    max_text = if focused?, do: "[#{max}]", else: to_string(max)
    affordance = if focused?, do: "  ← →", else: ""
    drain_text = if count > max, do: " drain", else: ""
    plain = "#{prefix}#{label} #{count}/#{max_text}#{drain_text}#{affordance}"
    pad = Text.padding_for(plain, inner_width)

    max_style =
      cond do
        alert? -> Style.red() <> Style.reverse()
        focused? -> Style.reverse()
        true -> Style.cyan()
      end

    [
      prefix,
      bold_label,
      " ",
      Style.cyan(),
      Integer.to_string(count),
      "/",
      max_style,
      max_text,
      Style.reset(),
      Style.cyan(),
      drain_text,
      affordance,
      Style.reset(),
      pad
    ]
  end

  @spec separator_row(term()) :: term()
  def separator_row(inner_width) do
    [
      Text.pad_with_ansi(
        Style.gray(),
        "├" <> String.duplicate("─", max(inner_width - 2, 0)),
        inner_width,
        "┤"
      )
    ]
  end

  @spec bottom_border(term()) :: term()
  def bottom_border(inner_width) do
    # Inject a "newest" label at the far-left of the bottom border so
    # the Executor can read the timeline direction in the events log:
    #   `╰─ newest ──...──╯`
    # The label sits between the `╰` corner and the trailing fill. When
    # the box is too narrow (`< 14` cols) for label + chrome, fall back
    # to the plain border so we never truncate the corner glyphs.
    label_text = "newest"
    label_visual = String.length(label_text)
    # ╰ + ─ + space + label + space + 1 trailing ─ minimum + ╯ = label_visual + 5
    min_for_label = label_visual + 6

    if inner_width >= min_for_label do
      trailing_fill = String.duplicate("─", max(inner_width - label_visual - 5, 0))

      [
        Style.gray(),
        "╰─ ",
        Style.reset(),
        Style.gray(),
        IO.ANSI.italic(),
        label_text,
        Style.reset(),
        Style.gray(),
        " ",
        trailing_fill,
        "╯",
        Style.reset()
      ]
    else
      [
        Text.pad_with_ansi(
          Style.gray(),
          "╰" <> String.duplicate("─", max(inner_width - 2, 0)),
          inner_width,
          "╯"
        )
      ]
    end
  end

  # Footer keybinds. `v layout` rides on the full row when there's
  # room, otherwise wraps to a second row so we don't truncate the more
  # frequently used keybinds (select/open/pause/remote/help/quit).
  @keybinds_full "↑/↓ select   enter open   space pause/resume   r remote   v layout   ? help   q quit"
  @keybinds_primary "↑/↓ select   enter open   space pause/resume   r remote   ? help   q quit"
  @keybinds_secondary "v layout"
  @footer_left_padding 2
  @footer_left_padding_str "  "

  # Bottom rows: keybinds rendered BELOW the bordered AgentList box (no
  # right `│` wall). The cascade prefers fewer rows when width permits.
  #
  # - 1 row: full keybinds fit
  # - 2 rows: primary keybinds, "v layout" below (narrow)
  @spec footer_split(term(), term()) :: term()
  def footer_split(inner_width, rc_line) do
    base = footer_keybinds_split(inner_width)

    case rc_line do
      text when is_binary(text) and text != "" ->
        rc_row = [
          left_only_row(
            Text.truncate(text, max(inner_width - @footer_left_padding - 1, 0)),
            inner_width
          ),
          Text.eol()
        ]

        %{iodata: [rc_row | base.iodata], line_count: base.line_count + 1}

      _ ->
        base
    end
  end

  @spec footer_keybinds_split(term()) :: term()
  def footer_keybinds_split(inner_width) do
    if Text.visual_width(@footer_left_padding_str <> @keybinds_full) + 1 <= inner_width do
      %{iodata: [left_only_row(@keybinds_full, inner_width), Text.eol()], line_count: 1}
    else
      %{
        iodata: [
          left_only_row(@keybinds_primary, inner_width),
          Text.eol(),
          left_only_row(@keybinds_secondary, inner_width),
          Text.eol()
        ],
        line_count: 2
      }
    end
  end

  # RC footer text: just the transient hint (immediate feedback after the
  # `r`/Space toggle). The session URL itself now rides in the agent's
  # chat-pane top border (set via tmux in `Aiur.AgentList.App`) so it
  # travels with the pane it belongs to instead of floating in the footer.
  @spec rc_footer_text(term()) :: term()
  def rc_footer_text(state) do
    case Map.get(state, :remote_control_hint) do
      hint when is_binary(hint) and hint != "" -> hint
      _ -> nil
    end
  end

  @spec left_only_row(term(), term()) :: term()
  def left_only_row(text, inner_width) do
    body = String.duplicate(" ", @footer_left_padding) <> text
    Text.pad_with_ansi(Style.dim(), body, inner_width, " ")
  end
end
