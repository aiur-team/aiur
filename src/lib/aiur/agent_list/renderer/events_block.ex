defmodule Aiur.AgentList.Renderer.EventsBlock do
  @moduledoc """
  The events block renders INSIDE the AgentList box, separated from the
  agent rows by a `├──...──┤` divider when there are events to show.
  Three kinds:

    💬  publish — `Aiur.Events.Publisher.publish/3` accepted the event
    📬  receive — `Aiur.Events.SubscriptionStore` delivered the event
                   to a subscribing ticket
    📄  read    — the agent's queue consumed an `events_digest` item
                   (the digest reached the agent's prompt)

  Line format:
    `💬 99 Agent: "<message>"` (publish — source ticket is the agent)
    `📬 100 Agent received from 99: "<message>"` (cross-ticket receive)
    `📄 100 Agent ingested:` (read — minimal context)

  The table takes precedence for space: when `budget` is too small for
  the divider + a single event row, the block collapses to nothing.
  """

  alias Aiur.AgentList.Renderer.{EventLine, Links, Style, Text}

  @spec events_block(map(), non_neg_integer(), non_neg_integer()) :: {iodata(), non_neg_integer()}
  def events_block(state, inner_width, budget) do
    events = state |> Map.get(:debug_events, []) |> Enum.reject(&is_nil/1)

    cond do
      budget < 2 -> {[], 0}
      inner_width < 4 -> {[], 0}
      true -> render_events_block(state, events, inner_width, budget)
    end
  end

  @spec render_events_block(map(), [map()], non_neg_integer(), non_neg_integer()) :: {iodata(), non_neg_integer()}
  def render_events_block(state, events, inner_width, budget) do
    # Divider eats 1 row; remaining budget is the event capacity.
    # The block ALWAYS uses the full budget — when there are fewer
    # events than rows, empty `│ ... │` rows pad ABOVE the events so
    # the newest line sits flush with the bottom border (chat-log
    # layout: new at bottom, old scrolls up).
    capacity = max(budget - 1, 0)
    rendering_identifier = selected_identifier(state)
    repo = Links.repo_identity(state)

    # state.debug_events is newest-first. Format each entry, drop the
    # ones the formatter suppresses (self-echoes), then take the newest
    # `capacity` so suppressed entries don't eat the budget.
    visible_lines =
      events
      |> Stream.map(&EventLine.format_event_line(&1, rendering_identifier, repo))
      |> Stream.reject(&is_nil/1)
      |> Enum.take(capacity)
      |> Enum.reverse()

    deficit = max(capacity - length(visible_lines), 0)
    empty_rows = for _ <- 1..deficit//1, do: [empty_event_row(inner_width), Text.eol()]

    event_rows =
      Enum.flat_map(visible_lines, &[event_box_inner_row(&1, inner_width), Text.eol()])

    iodata = [
      events_divider_row(inner_width),
      Text.eol(),
      empty_rows,
      event_rows
    ]

    {iodata, 1 + capacity}
  end

  @spec selected_identifier(map()) :: String.t() | nil
  def selected_identifier(%{selection_index: idx, summaries: summaries})
      when is_list(summaries) do
    case Enum.at(summaries, idx) do
      %{identifier: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  def selected_identifier(_state), do: nil

  @spec events_divider_row(non_neg_integer()) :: iodata()
  def events_divider_row(inner_width) do
    # Inject an "oldest" label at the far-right of the divider so the
    # operator can read the timeline direction:
    #   `├──...── oldest ─┤`
    # When the box is too narrow (`< 14` cols) for label + chrome, fall
    # back to the plain divider so we never truncate the corner glyphs.
    label_text = "oldest"
    label_visual = String.length(label_text)
    min_for_label = label_visual + 6

    if inner_width >= min_for_label do
      leading_fill = String.duplicate("─", max(inner_width - label_visual - 5, 0))

      [
        Style.gray(),
        "├",
        leading_fill,
        " ",
        Style.reset(),
        Style.gray(),
        IO.ANSI.italic(),
        label_text,
        Style.reset(),
        Style.gray(),
        " ─┤",
        Style.reset()
      ]
    else
      fill = String.duplicate("─", max(inner_width - 2, 0))
      [Style.gray(), "├", fill, "┤", Style.reset()]
    end
  end

  @spec event_box_inner_row(String.t(), non_neg_integer()) :: iodata()
  def event_box_inner_row(text, inner_width) do
    body_width = max(inner_width - 4, 0)
    padded = Text.clip_and_pad(text, body_width)
    [IO.ANSI.faint(), "│ ", padded, " │", IO.ANSI.reset()]
  end

  @spec empty_event_row(non_neg_integer()) :: iodata()
  def empty_event_row(inner_width) do
    fill = String.duplicate(" ", max(inner_width - 2, 0))
    [Style.gray(), "│", Style.reset(), fill, Style.gray(), "│", Style.reset()]
  end
end
