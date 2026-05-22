defmodule Aiur.Regression.MultiPaneOpenTest do
  @moduledoc """
  Regression for "cannot open a second chat pane" (reported 2026-05-21).

  After opening one chat pane successfully, the second open failed with:

      opencode_slot phase=respawn_attach_failed slot=2
      session_id=ses_... reason={:error, "no space for new pane"}

  Root cause: tmux's `split-window -l 50%` halves the target pane each
  call. The slot always splits FROM the keep-alive sentinel pane in
  aiur-hidden. After 5 pre-warm splits the sentinel is ~11 columns
  wide; after a couple of rebuild+respawn cycles it shrinks below
  tmux's minimum pane width and the split errors out.

  The slot's two split sites (`spawn_attach` pre-warm + `respawn_attach
  _with_session` rebuild) MUST run `select-layout even-horizontal`
  before splitting so the sentinel pane is reflowed back to a
  splittable width.
  """

  use ExUnit.Case, async: true

  @slot_source Path.expand("../../../lib/aiur/opencode/slot.ex", __DIR__)

  describe "slot keeps the hidden window splittable across many rebuilds" do
    test "respawn_attach_with_session calls reflow_hidden_window before split" do
      source = File.read!(@slot_source)
      block = extract_function(source, "respawn_attach_with_session")

      assert block =~ ~r/reflow_hidden_window\(keep_alive_pane\)/,
             """
             respawn_attach_with_session MUST call reflow_hidden_window
             before split_pane. Without the reflow, repeated kill+split
             cycles shrink the sentinel pane until tmux returns
             `no space for new pane`. Symptom: second chat pane fails
             to open with `respawn_attach_failed reason=:respawn_failed`.
             """
    end

    test "spawn_attach calls reflow_hidden_window before split" do
      source = File.read!(@slot_source)
      block = extract_function(source, "mark_ready_with_attach_pane")

      assert block =~ ~r/reflow_hidden_window\(keep_alive_pane\)/,
             """
             The spawn_attach chain MUST call reflow_hidden_window before
             split_pane for the same reason as respawn — repeated
             pre-warm/rebuild cycles otherwise leak pane width and the
             split eventually fails. mark_ready_with_attach_pane is the
             helper called from handle_continue(:spawn_attach, ...).
             """
    end

    test "reflow_hidden_window runs `select-layout even-horizontal`" do
      source = File.read!(@slot_source)

      assert source =~ ~r/defp reflow_hidden_window\(keep_alive_pane\)/,
             "reflow_hidden_window/1 must exist"

      assert source =~ ~r/select-layout -t #\{keep_alive_pane\} even-horizontal/,
             """
             reflow_hidden_window MUST run `select-layout even-horizontal`
             to redistribute pane widths in the hidden window. Other layouts
             (main-vertical, tiled) don't put the sentinel back to a
             reliably splittable width.
             """
    end
  end

  # Extract a function body by name. Stops at the next `defp `, `def `,
  # `end\n\n  defp `, or end-of-module.
  defp extract_function(source, fn_pattern) do
    case Regex.run(
           ~r/(?:def|defp)\s+#{fn_pattern}.*?\n  end\n/s,
           source
         ) do
      [match | _] -> match
      _ -> raise "could not extract function matching #{fn_pattern}"
    end
  end
end
