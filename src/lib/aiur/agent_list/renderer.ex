defmodule Aiur.AgentList.Renderer do
  @moduledoc """
  Pure rendering function for the agent-list pane.

  It owns frame composition, the layout-map fan-in, and terminal escape
  discipline while leaf modules render each visual concern.
  """

  alias Aiur.AgentEvents
  alias Aiur.AgentList.Renderer.{Chrome, EventsBlock, Help, Layout, Markers, Table, Text}

  @type state :: %{
          required(:summaries) => [AgentEvents.agent_summary()],
          required(:selection_index) => non_neg_integer(),
          optional(:selection_focus) => :agents | :max_agents,
          required(:columns) => pos_integer(),
          required(:rows) => pos_integer(),
          required(:project_label) => String.t() | nil,
          required(:dashboard_url) => String.t() | nil
        }

  @spec render(state()) :: iodata()
  def render(state) when is_map(state) do
    cols = Map.get(state, :columns, 80)
    rows = Map.get(state, :rows, 24)
    inner_width = max(cols - 1, 1)

    if Map.get(state, :help_visible?, false) do
      {drawn, drawn_count} = Help.render(inner_width)
      drawn ++ [clear_remaining(rows, drawn_count)]
    else
      summaries = Map.get(state, :summaries, [])

      layout =
        summaries
        |> Layout.compute(inner_width)
        |> Map.put(:open_attentions_by_id, Map.get(state, :open_attentions_by_id, %{}))
        |> Map.put(:latest_event_by_id, Map.get(state, :latest_event_by_id, %{}))
        |> Map.put(:attach_state, Map.get(state, :attach_state, %{}))
        |> Map.put(:agents_with_content, Map.get(state, :agents_with_content, MapSet.new()))
        |> Map.put(:progress_by_id, Map.get(state, :progress_by_id, %{}))
        |> Map.put(:phase_by_identifier, Map.get(state, :phase_by_identifier, %{}))
        |> Map.put(:now_ms, Map.get(state, :now_ms, System.monotonic_time(:millisecond)))
        |> Map.put(:prewarm_active?, Map.get(state, :prewarm_active?, false))
        |> Map.put(:prewarm_phase, Map.get(state, :prewarm_phase))
        |> Map.put(:project_label, Map.get(state, :project_label))
        |> Map.put(:truecolor?, Map.get(state, :truecolor?, true))

      markers = Markers.compute_markers(state, summaries)
      footer_render = Chrome.footer_split(inner_width, Chrome.rc_footer_text(state))
      footer_lines = footer_render.line_count
      base_lines = lines_emitted(state, inner_width, footer_lines)
      events_budget = max(rows - base_lines - 1, 0)
      {events_iodata, events_line_count} = EventsBlock.events_block(state, inner_width, events_budget)

      [
        "\e[?2026h",
        "\e[?25l",
        "\e[?12l",
        "\e[H",
        Chrome.title_row(inner_width),
        Text.eol(),
        Chrome.metadata_rows(state, inner_width),
        Chrome.separator_row(inner_width),
        Text.eol(),
        Table.table_header_row(inner_width, layout),
        Text.eol(),
        Table.table_separator_row(inner_width, layout),
        Text.eol(),
        Table.render_rows(summaries, Map.get(state, :selection_index, 0), Map.get(state, :selection_focus, :agents), inner_width, layout, markers),
        events_iodata,
        Chrome.bottom_border(inner_width),
        Text.eol(),
        footer_render.iodata,
        clear_remaining(rows, base_lines + events_line_count),
        "\e[?25l",
        "\e[?12l",
        "\e[H",
        "\e[?2026l"
      ]
    end
  end

  # Approximate count of rows the frame will draw (used for "blank the
  # rest" below the last rendered row so old content doesn't linger
  # when the agent list shrinks).
  defp lines_emitted(state, _inner_width, footer_lines) do
    summaries = Map.get(state, :summaries, [])
    body_rows = if summaries == [], do: 1, else: length(summaries)
    8 + footer_lines + body_rows
  end

  defp clear_remaining(rows, lines_drawn) do
    if lines_drawn >= rows do
      []
    else
      [["\e[", Integer.to_string(lines_drawn + 1), ";1H"], "\e[J"]
    end
  end
end
