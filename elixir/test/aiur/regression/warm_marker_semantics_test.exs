defmodule Aiur.Regression.WarmMarkerSemanticsTest do
  @moduledoc """
  Regression for "● appeared on agent rows before ⚡" (reported
  2026-05-21). Two interlocking guarantees the renderer must keep:

  1. ⚡ ONLY appears on rows whose opencode-attach is fully painted
     and ready to instant-open. Promised by AttachPool's
     `wait_for_paint` gate — if paint times out, we send
     :attach_failed and the identifier never enters warm_identifiers.

  2. ● ONLY appears on rows whose pane is actually visible to the
     user. `visible_sessions` is populated from :slot_session_changed
     which fires during AttachPool's warming (before paint). The
     renderer strips warming + warm ids from visible_sessions so
     ● never paints a row mid-warm.

  3. AttachPool broadcasts {:attach_warming, id, slot} when it
     dispatches a warm Task so AgentList can populate
     warming_identifiers immediately. Without this broadcast there's
     a several-second window where ● would falsely paint.

  Also asserts ⚡ formatting: must occupy 3 visible cols to match ●.
  """

  use ExUnit.Case, async: true

  @attach_pool_source Path.expand("../../../lib/aiur/opencode/attach_pool.ex", __DIR__)
  @app_source Path.expand("../../../lib/aiur/agent_list/app.ex", __DIR__)
  @renderer_source Path.expand("../../../lib/aiur/agent_list/renderer.ex", __DIR__)

  describe "wait_for_paint gates warm" do
    test "AttachPool waits for `Build · issue-` paint before flipping to :warm" do
      source = File.read!(@attach_pool_source)

      assert source =~ ~r/defp wait_for_paint\(pane_id,/,
             "wait_for_paint/2 must exist"

      assert source =~ ~r/"Build · issue-"/,
             """
             wait_for_paint MUST grep for the opencode message-turn
             marker. Anything else (e.g. checking for non-empty
             content) would flip warm before opencode has rendered.
             """
    end

    test "paint_timeout drops the attachment (does NOT mark warm)" do
      source = File.read!(@attach_pool_source)

      # Get the spawn_warm_attach body
      spawn_block =
        case Regex.run(~r/defp spawn_warm_attach.*?\n  end\n/s, source) do
          [m | _] -> m
          _ -> raise "could not extract spawn_warm_attach"
        end

      assert spawn_block =~ ~r/:timeout ->\s*\n[^}]*?send\(pool, \{:attach_failed/,
             """
             On wait_for_paint :timeout, spawn_warm_attach MUST send
             :attach_failed (not :attach_warmed). The ⚡ icon is a
             PROMISE that pressing Enter opens opencode in <1 s.
             Marking warm on timeout breaks that promise — the user
             sees ⚡ on a row whose attach is dead or still booting.
             """

      refute spawn_block =~
               ~r/:timeout ->\s*\n[^}]*?send\(pool, \{:attach_warmed/,
             """
             spawn_warm_attach must NOT send :attach_warmed on paint
             timeout. (Previous version did this as a 'best effort'
             but it lied to the user.)
             """
    end
  end

  describe "● is suppressed during warming + warm" do
    test "AttachPool broadcasts :attach_warming when dispatching warm Task" do
      source = File.read!(@attach_pool_source)

      assert source =~ ~r/broadcast_event\(\{:attach_warming,/,
             """
             AttachPool MUST broadcast :attach_warming as soon as it
             dispatches a warm Task. AgentList listens for this so
             it can add the identifier to warming_identifiers BEFORE
             :slot_session_changed fires from Slot.select. Without
             this broadcast, ● falsely paints on the row for the
             5-15 s window between Slot.select and paint completion.
             """
    end

    test "AgentList tracks warming_identifiers in state" do
      source = File.read!(@app_source)

      assert source =~ ~r/warming_identifiers:\s*MapSet\.new\(\)/,
             "AgentList state MUST initialize warming_identifiers"

      assert source =~ ~r/def handle_info\(\{:attach_warming,/,
             "AgentList MUST handle the :attach_warming PubSub event"
    end

    test "renderer strips warming + warm from visible_identifiers" do
      source = File.read!(@renderer_source)

      visible_block =
        case Regex.run(~r/defp visible_identifiers.*?\n  end\n/s, source) do
          [m | _] -> m
          _ -> raise "could not extract visible_identifiers"
        end

      assert visible_block =~ ~r/MapSet\.difference\(.*warming/,
             """
             visible_identifiers MUST subtract warming_identifiers
             from the raw visible_sessions set. Otherwise ● paints
             on every row whose slot session is selected — including
             warming-in-progress rows where no pane is visible yet.
             """

      assert visible_block =~ ~r/MapSet\.difference\(.*warm/,
             """
             visible_identifiers MUST subtract warm_identifiers too
             (defensive — a warm row should show ⚡ not ●).
             """
    end
  end

  describe "⚡ formatting matches ● width" do
    test "warm marker pads to 3 visible cols" do
      source = File.read!(@renderer_source)

      marker_block =
        case Regex.run(~r/defp id_age_gap_marker.*?\n  end\n/s, source) do
          [m | _] -> m
          _ -> raise "could not extract id_age_gap_marker"
        end

      # ⚡ (U+26A1) is East Asian Width=Narrow but renders 2 cols in
      # most modern terminals. ● is 1 col + 2 spaces = 3 cols. ⚡'s
      # marker must include trailing space so total is at least 3
      # cols (4 if terminal renders ⚡ wide — never short).
      assert marker_block =~ ~r/@warm_pane_glyph.*?,\s*IO\.ANSI\.reset\(\),\s*" "/,
             """
             The ⚡ marker MUST include a trailing space (after
             IO.ANSI.reset) to match ●'s 3-col cell width. ⚡ is
             East Asian Width=Narrow; some terminals render it 1 col
             wide. Without the trailing space the warm marker is
             1-col short of the open marker, breaking column
             alignment.
             """

      # ⚡ takes precedence over ● (warm IS visible if we already
      # subtract them from visible_identifiers, but renderer
      # precedence is the defensive backstop).
      precedence_order = ["@warm_pane_glyph", "@open_pane_glyph"]
      positions = Enum.map(precedence_order, &index_of(marker_block, &1))

      assert positions == Enum.sort(positions),
             """
             id_age_gap_marker MUST check warm_ids BEFORE open_pane_ids.
             ⚡ wins over ●. (visible_identifiers already strips warm
             ids, so this is a defensive backstop.)
             """
    end

    test "marker constants are defined" do
      source = File.read!(@renderer_source)

      assert source =~ ~r/@warm_pane_glyph\s+"⚡"/,
             "@warm_pane_glyph constant MUST be ⚡ (U+26A1 HIGH VOLTAGE SIGN)"

      assert source =~ ~r/@open_pane_glyph\s+"●"/,
             "@open_pane_glyph constant MUST be ● (U+25CF BLACK CIRCLE)"
    end
  end

  defp index_of(haystack, needle) do
    case :binary.match(haystack, needle) do
      {pos, _} -> pos
      :nomatch -> -1
    end
  end
end
