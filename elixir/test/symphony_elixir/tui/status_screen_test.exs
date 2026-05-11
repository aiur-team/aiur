defmodule SymphonyElixir.TUI.StatusScreenTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TUI.State
  alias SymphonyElixir.TUI.Widgets.StatusScreen

  test "renders the current dashboard sections" do
    rendered = StatusScreen.render_text(state(snapshot(["MT-101", "MT-102"]), 0))

    assert rendered =~ "SYMPHONY STATUS"
    assert rendered =~ "Agents: 2/"
    assert rendered =~ "Project:"
    assert rendered =~ "├─ Running"
    assert rendered =~ "├─ Backoff queue"
    assert rendered =~ "MT-101"
    assert rendered =~ "MT-102"
  end

  test "marks the selected running agent" do
    rendered = StatusScreen.render_text(state(snapshot(["MT-101", "MT-102"]), 1))

    assert rendered =~ "│   MT-101"
    assert rendered =~ "│ ● MT-102"
  end

  test "renders empty running and retry states" do
    rendered = StatusScreen.render_text(state(snapshot([]), nil))

    assert rendered =~ "No active agents"
    assert rendered =~ "No queued retries"
  end

  test "renders unavailable snapshots" do
    rendered = StatusScreen.render_text(state(:error, nil))

    assert rendered =~ "Orchestrator snapshot unavailable"
  end

  test "returns a full-screen paragraph widget for ExRatatui" do
    frame = %ExRatatui.Frame{width: 100, height: 30}

    rows = StatusScreen.render(state(snapshot(["MT-101"]), 0), frame)

    assert {%ExRatatui.Widgets.Paragraph{text: "╭─ SYMPHONY STATUS"}, %ExRatatui.Layout.Rect{x: 0, y: 0, width: 100, height: 1}} =
             List.first(rows)

    assert Enum.all?(rows, fn {%ExRatatui.Widgets.Paragraph{text: text}, %ExRatatui.Layout.Rect{x: x, height: height}} ->
             x == 0 and height == 1 and not String.contains?(text, "\n")
           end)
  end

  defp state(snapshot, selected_index) do
    %State{
      snapshot: snapshot,
      selected_index: selected_index,
      snapshot_source: fn -> snapshot end,
      refresh_ms: 1_000
    }
  end

  defp snapshot(identifiers) do
    {:ok,
     %{
       running:
         Enum.map(identifiers, fn identifier ->
           %{
             identifier: identifier,
             state: "running",
             codex_app_server_pid: "1234",
             runtime_seconds: 75,
             turn_count: 2,
             agent_total_tokens: 1_234,
             session_id: "thread-1234567890",
             last_codex_message: nil
           }
         end),
       retrying: [],
       agent_totals: %{
         input_tokens: 10,
         output_tokens: 20,
         total_tokens: 30,
         seconds_running: 75
       },
       rate_limits: nil,
       polling: %{checking?: false, next_poll_in_ms: 2_000}
     }}
  end
end
