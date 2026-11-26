defmodule AiurWeb.Executor.PanelsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias AiurWeb.Executor.{BackgroundAgentsPanel, BlockersPanel}

  test "unsupported background agents render the reason and no roster" do
    html = render_component(&BackgroundAgentsPanel.panel/1, snapshot: {:unsupported, :fields_unverified}, now: DateTime.utc_now())
    assert html =~ "Not available for this harness (fields_unverified)"
    refute html =~ "No background agents"
    refute html =~ "<li"
    refute html =~ ">0"
  end

  test "available background agents distinguish an empty roster from escaped, bounded messages" do
    now = DateTime.utc_now()
    assert render_component(&BackgroundAgentsPanel.panel/1, snapshot: {:ok, [], now}, now: now) =~ "No background agents"
    message = "<b>Literal text</b>" <> String.duplicate("x", 500)
    row = %{agent_id: "a", agent_type: "Explore", state: :finished, started_at: DateTime.add(now, -120, :second), last_message: message}
    html = render_component(&BackgroundAgentsPanel.panel/1, snapshot: {:ok, [row], now}, now: now)

    assert html =~ "Explore"
    assert html =~ "finished · 2 minutes"
    assert html =~ Phoenix.HTML.html_escape(String.slice(message, 0, 500)) |> Phoenix.HTML.safe_to_string()
    refute html =~ "<b>Literal text</b>"
    refute html =~ String.duplicate("x", 500)
  end

  test "unavailable blockers show their reason instead of the empty state" do
    snapshot = %{items: [], sources: %{asks: {:unavailable, :corrupt}, fleet: :ok, commands: :ok}}
    html = blockers(snapshot)
    assert html =~ ~s(id="executor-blockers-asks")
    assert html =~ "Unavailable (corrupt)"
    refute html =~ "No Executor blockers"
    assert blockers(put_in(snapshot.sources.asks, :ok)) =~ "No Executor blockers"
  end

  test "fleet blockers and asks remain usable when Commands are unavailable" do
    items = [
      %{kind: :ask, id: "ask_abc", link: "/commands", age_ms: 120_000, title: "Approve plan"},
      %{kind: :fleet, id: "system.fleet.capacity.starved", link: "/", age_ms: nil, title: "Fleet needs capacity"}
    ]

    html = blockers(%{items: items, sources: %{asks: :ok, fleet: :ok, commands: {:unavailable, :timeout}}})
    assert html =~ ~s(href="/commands">Approve plan)
    assert html =~ "aiur ask --done ask_abc"
    assert html =~ ~s(href="/">Fleet needs capacity)
    assert html =~ "age unknown"
    assert html =~ "2 minutes"
    assert html =~ "Unavailable (timeout)"
  end

  defp blockers(snapshot), do: render_component(&BlockersPanel.panel/1, snapshot: snapshot, decisions: [], actions: %{}, writable: false)
end
