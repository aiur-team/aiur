defmodule Aiur.AgentList.Renderer.Markers do
  @moduledoc """
  Computes pane-readiness markers and workflow-state emoji for agent rows.
  It keeps the warm-marker precedence in one pure module.
  """

  alias Aiur.AgentEvents

  # Work states meaning the agent has finished this iteration. Used to
  # render 🏁 and to suppress the warming/starting LATEST placeholder so
  # a finished agent never freezes on "Warming up…" (#425). Named
  # "finished" rather than "terminal" because this module already uses
  # "terminal" for the TTY.
  @finished_work_states [:deactivated, "deactivated", :done, "done"]

  # Work states the renderer paints with `AgentEvents.state_emoji/1`
  # (each has a canonical glyph) rather than the warm-marker progression
  # (⏳ → 🔘 → ⚪ → 🟢). Superset of @finished_work_states plus the
  # still-alive paused/error/sleeping states (`:sleeping` → 💤, #418) —
  # derived from @finished_work_states so a future finished state lands
  # in both sets at once.
  @state_emoji_work_states [
                             :paused,
                             "paused",
                             :error,
                             "error",
                             :sleeping,
                             "sleeping",
                             :completed,
                             "completed"
                           ] ++ @finished_work_states

  # Per-identifier marker, ordered most-ready-first:
  #
  #   🟢  agent's pane is open in window 0 right now
  #       (`opened_panes`, populated by PaneManager pane_opened/closed events)
  #   ⚪  agent's leadoff slot has finished painting in the hidden window
  #       AND the agent has emitted at least one transcript event —
  #       opening shows meaningful content immediately.
  #       (`attach_state[id].visible_in` is set, AND `id` is in
  #       `agents_with_content`)
  #   🔘  agent's leadoff slot has painted (instant-open) but the codex
  #       turn hasn't produced any transcript content yet — opening
  #       shows just Build chrome and a blank pane until content
  #       streams in. This is the "pre-warmed, agent still warming up"
  #       in-between state.
  #   ⏳  no instant-open path yet: slot hasn't painted (or no slot has
  #       attached this identifier at all). Opening requires a respawn.
  #
  # `agents_with_content` is mirrored from per-agent transcript
  # broadcasts: once any transcript_event fires for an identifier, the
  # AgentList state adds it to this set and the marker promotes ⚪.
  @spec compute_markers(term(), term()) :: term()
  def compute_markers(state, summaries) do
    attach_state = Map.get(state, :attach_state, %{})
    opened_panes = Map.get(state, :opened_panes, MapSet.new())
    agents_with_content = Map.get(state, :agents_with_content, MapSet.new())

    Enum.reduce(summaries, %{}, fn summary, acc ->
      id = to_string(Map.get(summary, :identifier) || "")

      Map.put(
        acc,
        id,
        marker_for_identifier(id, opened_panes, attach_state, agents_with_content)
      )
    end)
  end

  @spec marker_for_identifier(term(), term(), term(), term()) :: term()
  def marker_for_identifier(id, opened_panes, attach_state, agents_with_content) do
    if MapSet.member?(opened_panes, id) do
      "🟢"
    else
      marker_from_attach(Map.get(attach_state, id), MapSet.member?(agents_with_content, id))
    end
  end

  @spec marker_from_attach(term(), term()) :: term()
  def marker_from_attach(%{visible_in: slot}, true) when not is_nil(slot), do: "⚪"
  def marker_from_attach(%{visible_in: slot}, _has_content) when not is_nil(slot), do: "🔘"
  def marker_from_attach(_attach, _has_content), do: "⏳"

  # `summary_emoji` shows, for a running working agent, the active
  # workflow phase (🧠/📋/🔨/🔍 — #68) when one is known, falling back
  # to the precomputed instant-open marker otherwise. Pre-warm ⏳ still
  # wins while the pane isn't warm. Paused/error/done/deactivated defer
  # to AgentEvents.
  @spec summary_emoji(term(), term(), term()) :: term()
  def summary_emoji(%{status: :queued}, _markers, _phase), do: "⚫"

  def summary_emoji(%{status: :running, identifier: identifier} = summary, markers, phase) do
    case Map.get(summary, :work_state) do
      state when state in @state_emoji_work_states ->
        # `:deactivated` (and `:done`) are terminal: route through
        # AgentEvents.state_emoji so a finished agent reaches 🏁 instead
        # of falling through to the warm-marker logic and freezing on ⏳
        # (#425). emoji_sort_key and the progress seeding already treat
        # these as finished; the renderer was the lone surface out of
        # sync. `:sleeping` is still-alive but also routes through
        # AgentEvents.state_emoji for its 💤 glyph (#418).
        AgentEvents.state_emoji(state)

      _ ->
        marker = Map.get(markers, to_string(identifier), "⏳")

        if marker == "⏳" do
          "⏳"
        else
          phase_emoji(phase) || marker
        end
    end
  end

  def summary_emoji(%{work_state: work_state}, _markers, _phase),
    do: AgentEvents.state_emoji(work_state)

  def summary_emoji(_, _markers, _phase), do: "⚫"

  @spec phase_emoji(term()) :: term()
  def phase_emoji(:brainstorm), do: "🧠"
  def phase_emoji(:plan), do: "📋"
  # U+1F528 hammer, not the U+1F6E0+FE0F hammer-and-wrench: the latter
  # needs a variation selector to get emoji presentation, and terminals
  # that default it to text presentation (e.g. Termius on iOS) render it
  # one column wide, breaking the fixed-width column math here. The plain
  # hammer has default emoji presentation, so it stays two columns.
  def phase_emoji(:work), do: "🔨"
  def phase_emoji(:review), do: "🔍"
  def phase_emoji(_), do: nil

  @spec finished_work_state?(term()) :: term()
  def finished_work_state?(state), do: state in @finished_work_states
end
