defmodule Aiur.AgentList.RcPaneBordersTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.RcPaneBorders

  describe "changes/3 (RC pane-border reconciliation)" do
    test "an open pane whose agent has a live RC URL gets a border-set change" do
      url = "https://claude.ai/code/session_ABC"
      summaries = [%{identifier: "101", remote_control: %{status: :on, session_url: url}}]

      {changes, applied} = RcPaneBorders.changes(%{"101" => "%9"}, summaries, %{})

      assert [{"%9", text}] = changes
      assert text =~ url
      assert applied == %{"%9" => text}
    end

    test "a pane already showing the same URL produces no change (dedup keeps the 1 Hz tick quiet)" do
      url = "https://claude.ai/code/session_ABC"
      summaries = [%{identifier: "101", remote_control: %{status: :on, session_url: url}}]
      text = " 📱 #{url} "

      {changes, applied} = RcPaneBorders.changes(%{"101" => "%9"}, summaries, %{"%9" => text})

      assert changes == []
      assert applied == %{"%9" => text}
    end

    test "turning RC off on an open pane emits a clear (nil) change and drops the tracking entry" do
      url = "https://claude.ai/code/session_ABC"
      summaries = [%{identifier: "101", remote_control: %{status: :off}}]

      {changes, applied} = RcPaneBorders.changes(%{"101" => "%9"}, summaries, %{"%9" => " 📱 #{url} "})

      assert changes == [{"%9", nil}]
      assert applied == %{}
    end

    test "an open pane whose agent has no RC at all carries no border" do
      summaries = [%{identifier: "101", status: :running}]

      {changes, applied} = RcPaneBorders.changes(%{"101" => "%9"}, summaries, %{})

      assert changes == []
      assert applied == %{}
    end

    test "a closed pane self-prunes from tracking without an explicit clear" do
      summaries = []

      {changes, applied} = RcPaneBorders.changes(%{}, summaries, %{"%9" => " 📱 url "})

      assert changes == []
      assert applied == %{}
    end

    test "a literal # in the URL is doubled so tmux's pane-border-format can't expand it" do
      url = "https://claude.ai/code/session_#weird"
      summaries = [%{identifier: "101", remote_control: %{status: :on, session_url: url}}]

      {[{"%9", text}], _applied} = RcPaneBorders.changes(%{"101" => "%9"}, summaries, %{})

      assert text =~ "session_##weird"
    end
  end

  test "leaves borders untouched when PaneManager is unavailable" do
    state = %{pane_manager: :not_registered, summaries: [], rc_pane_borders: %{"%9" => " 📱 url "}, tmux: :unused}
    assert RcPaneBorders.reconcile(state) == state
  end
end
