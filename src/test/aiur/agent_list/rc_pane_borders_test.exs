defmodule Aiur.AgentList.RcPaneBordersTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.RcPaneBorders

  test "computes set, deduplicated, clearing, and pruned border changes" do
    url = "https://claude.ai/code/session_#weird"
    summaries = [%{identifier: "101", remote_control: %{status: :on, session_url: url}}]
    {[{"%9", text}], applied} = RcPaneBorders.changes(%{"101" => "%9"}, summaries, %{})
    assert text =~ "session_##weird"
    assert {[], ^applied} = RcPaneBorders.changes(%{"101" => "%9"}, summaries, applied)
    assert {[{"%9", nil}], %{}} = RcPaneBorders.changes(%{"101" => "%9"}, [%{identifier: "101"}], applied)
    assert {[], %{}} = RcPaneBorders.changes(%{}, [], applied)
  end

  test "leaves borders untouched when PaneManager is unavailable" do
    state = %{pane_manager: :not_registered, summaries: [], rc_pane_borders: %{"%9" => " 📱 url "}, tmux: :unused}
    assert RcPaneBorders.reconcile(state) == state
  end
end
