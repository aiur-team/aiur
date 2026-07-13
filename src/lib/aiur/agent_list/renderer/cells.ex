defmodule Aiur.AgentList.Renderer.Cells do
  @moduledoc """
  Renders individual table cells, progress, runtime, and latest placeholders.
  It uses the facade-captured clock to keep a frame internally consistent.
  """

  alias Aiur.AgentList.Renderer.{Layout, Links, Markers, Model, Style, Text}
  alias Aiur.ProgressTracker

  # Faint dotted track shown in the PROGRESS column when an agent has no
  # samples yet. A full row of `░` (the bar's empty-cell glyph) reads as
  # a corrupt/half-filled bar (#425); the dotted track reads
  # unambiguously as "no progress data yet" while keeping the fixed
  # Layout.progress_bar_width().
  @empty_progress_track String.duplicate("·", Layout.progress_bar_width())

  # Wrap a padded ID cell in an OSC 8 hyperlink to the ticket's
  # web page when the renderer knows the project (e.g.
  # "its-everdred/aiur") AND the identifier looks like a GitHub
  # issue number. Terminals that support OSC 8 (iTerm2, WezTerm,
  # Ghostty, etc.) render the cell as a click-to-open link; those
  # that don't ignore the escapes and display the digits as plain
  # text. Width calculations are unaffected because OSC sequences
  # have zero visual width.
  @spec id_cell_with_link(term(), term()) :: term()
  def id_cell_with_link(id_str, layout) do
    padded = Text.cell(id_str, layout.id_width)
    project = Map.get(layout, :project_label)

    case Links.ticket_url(project, id_str) do
      nil -> padded
      url -> "\e]8;;" <> url <> "\e\\" <> padded <> "\e]8;;\e\\"
    end
  end

  # `❗` cell: blank-but-allocated when zero attentions open; `❗`
  # alone (two terminal columns + space) when one; `❗N` when more.
  # Width stays Layout.attention_cell_width() either way so the Latest
  # column never shifts horizontally on flip.
  @spec attention_cell(term(), term()) :: term()
  def attention_cell(id, layout) do
    count = layout |> Map.get(:open_attentions_by_id, %{}) |> Map.get(id, 0)

    text =
      cond do
        count <= 0 -> ""
        count == 1 -> "❗"
        count >= 10 -> "❗9+"
        true -> "❗#{count}"
      end

    Text.emoji_cell(text, Layout.attention_cell_width())
  end

  # Remote-control indicator cell. `:launching` shows 📲 (registration
  # is a network round-trip, so the Executor gets feedback the instant
  # `r` is pressed, before the URL lands — a distinct glyph from the ⏳
  # warming marker so the two never read as the same state); `:on`
  # shows 📱; `:failed` shows ❌; `:off`/absent shows nothing. Width is
  # fixed at Layout.rc_cell_width() regardless so column alignment never shifts.
  @spec rc_cell(term()) :: term()
  def rc_cell(summary) do
    glyph =
      case Map.get(summary, :remote_control) do
        %{status: :launching} -> "📲"
        %{status: :on} -> "📱"
        %{status: :failed} -> "❌"
        _ -> ""
      end

    Text.emoji_cell(glyph, Layout.rc_cell_width())
  end

  # Progress + ETA pair, rendered as one cell of fixed width 16:
  # `<bar 10> <eta 5>`. When the tracker has no samples for the id we
  # render the faint dotted @empty_progress_track (not a full row of
  # `░`, which reads as a corrupt/half-filled bar — #425). Width stays
  # the same either way so the column never jitters.
  #
  # At percent: 100 (the agent's stop-work signal — see
  # `src/prompts/shared-agent-instructions.md`'s "Progress emits"
  # section), the bar is tinted green so the Executor sees at a
  # glance that the agent is done for this iteration. The cell is
  # otherwise wrapped in `Style.dim()` at the call site; we reset and
  # re-apply dim around the green wrap so terminals render the
  # color cleanly.
  @spec progress_cell(term(), term()) :: term()
  def progress_cell(id, layout) do
    samples = layout |> Map.get(:progress_by_id, %{}) |> Map.get(id, [])
    now_ms = Map.get(layout, :now_ms, System.monotonic_time(:millisecond))

    case ProgressTracker.estimate(samples, now_ms) do
      :unknown ->
        @empty_progress_track

      %{percent: 100} ->
        full_bar = ProgressTracker.bar(100, Layout.progress_bar_width())
        Style.reset() <> Style.green() <> full_bar <> Style.reset() <> Style.dim()

      %{percent: pct} ->
        ProgressTracker.bar(pct, Layout.progress_bar_width())
    end
  end

  # Cumulative wall-clock the agent has been running. Always-on; ticks
  # up every render. Source: `summary.runtime_seconds`, already kept
  # current by AgentList.App on every poll. Format chosen so the
  # column never widens:
  #   * <60s   → `0:01` … `0:59`
  #   * <60m   → `1:23` … `59:59`
  #   * <10h   → `1:02:03` (h:MM:SS — fits Layout.runtime_cell_width() 7)
  #   * ≥10h   → `Nh` short form (rare; stays inside the cell)
  @spec runtime_cell(term()) :: term()
  def runtime_cell(summary) do
    seconds = Map.get(summary, :runtime_seconds) || 0
    Text.cell(format_runtime(seconds), Layout.runtime_cell_width())
  end

  @spec format_runtime(term()) :: term()
  def format_runtime(seconds) when is_integer(seconds) and seconds < 0, do: "0:00"

  def format_runtime(seconds) when is_integer(seconds) and seconds < 3600 do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{mins}:#{pad2(secs)}"
  end

  def format_runtime(seconds) when is_integer(seconds) and seconds < 36_000 do
    hours = div(seconds, 3600)
    mins = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)
    "#{hours}:#{pad2(mins)}:#{pad2(secs)}"
  end

  def format_runtime(seconds) when is_integer(seconds), do: "#{div(seconds, 3600)}h"

  def format_runtime(_), do: "0:00"

  @spec pad2(term()) :: term()
  def pad2(n) when is_integer(n) and n < 10, do: "0#{n}"
  def pad2(n), do: "#{n}"

  # Latest column cell — current most-recent event message for the
  # ticket. When no event has landed yet, shows a phase-aware
  # placeholder with an animated spinner so the row feels alive
  # while the agent is queued/warming/starting. Truncated with `…`
  # when wider than the column.
  @spec latest_cell(term(), term(), term()) :: term()
  def latest_cell(id, layout, summary) do
    if layout.latest_width <= 0 do
      ""
    else
      text =
        case Map.get(layout, :latest_event_by_id, %{}) |> Map.get(id) do
          nil -> phase_placeholder(id, layout, summary)
          event -> latest_event_message(event)
        end

      Text.cell(text, layout.latest_width)
    end
  end

  # Braille spinner that advances ~10 frames per second so the
  # placeholder reads as "alive" even though our render tick is
  # 1 Hz — `now_ms / 100` rolls through the frame list as the
  # millisecond clock advances. Same frame within a single render
  # because `:now_ms` is captured once at the top of render/1.
  @spinner_frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  @spec spinner_frame(term()) :: term()
  def spinner_frame(layout) do
    now_ms = Map.get(layout, :now_ms, System.monotonic_time(:millisecond))
    idx = rem(div(now_ms, 100), length(@spinner_frames))
    Enum.at(@spinner_frames, idx)
  end

  # Decide what phase text to show in the LATEST column when no
  # real event has landed for this agent yet. Mirrors the marker
  # state machine so the placeholder advances visibly as the
  # agent's slot/codex come online.
  @spec phase_placeholder(term(), term(), term()) :: term()
  def phase_placeholder(id, layout, summary) do
    spinner = spinner_frame(layout)
    attach = Map.get(layout, :attach_state, %{}) |> Map.get(id)
    has_content = MapSet.member?(Map.get(layout, :agents_with_content, MapSet.new()), id)

    phrase =
      cond do
        # A finished (deactivated/done) agent has released its slot, so
        # `attach` is nil — but it is NOT warming up. Suppress the
        # warming/starting placeholder so the row doesn't freeze on
        # "Warming up…" after the agent has gone terminal (#425).
        Markers.finished_work_state?(Map.get(summary, :work_state)) -> ""
        Map.get(summary, :status) == :queued -> "Queueing agent…"
        is_nil(attach) -> "Warming up…"
        match?(%{visible_in: nil}, attach) -> "Warming up…"
        not has_content -> starting_phrase(summary)
        true -> ""
      end

    if phrase == "", do: "", else: spinner <> " " <> phrase
  end

  # The "Starting" placeholder should name the agent's own engine, not a
  # hardcoded backend. The summary carries the resolved backend string
  # (e.g. "claude-repl", "codex"); the engine family is its first segment.
  @spec starting_phrase(term()) :: term()
  def starting_phrase(summary) do
    case Model.engine_word(summary) do
      nil -> "Starting…"
      word -> "Starting #{word}…"
    end
  end

  @spec latest_event_message(term()) :: term()
  def latest_event_message(nil), do: ""
  def latest_event_message(%{message: msg}) when is_binary(msg), do: msg
  def latest_event_message(%{"message" => msg}) when is_binary(msg), do: msg
  def latest_event_message(_), do: ""
end
