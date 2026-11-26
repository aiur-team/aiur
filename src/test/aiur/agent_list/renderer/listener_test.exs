defmodule Aiur.AgentList.Renderer.ListenerTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentList.Renderer.{Layout, Listener, Table, Text}

  for {mode, copy} <- [async: "Async · pings only", mute: "Mute · silent"] do
    test "TUI listener row preserves #{mode} copy and unread count after Units retirement" do
      summary = %{identifier: "42", title: "Working", listener: %{effective: unquote(mode), requested: unquote(mode), unread_count: 2}}
      row = Table.render_row(summary, false, 160, Layout.compute([summary], 160), %{}) |> IO.iodata_to_binary()
      assert row =~ unquote(copy) <> " / 2 unread"
      assert Text.visual_width(Text.strip_ansi(row)) == 160
      refute row =~ "Async · on demand"
    end
  end

  test "row shows effective mode and requested when different with unread count" do
    summary = %{identifier: "42", title: "Working", listener: %{effective: :sync, requested: :steer, unread_count: 2}}
    layout = Layout.compute([summary], 160)
    row = Table.render_row(summary, false, 160, layout, %{}) |> IO.iodata_to_binary()
    assert row =~ "Sync · next turn (req Steer · interrupts) / 2 unread"
    assert Table.table_header_row(160, layout) |> IO.iodata_to_binary() =~ "LISTENER"
    assert Text.visual_width(Text.strip_ansi(row)) == 160
    assert Listener.label(%{effective: :async, requested: :async, unread_count: 0}) == "Async · pings only / 0 unread"
  end

  test "constrained row reserves the full listener label alongside long title and latest" do
    summary = %{identifier: "42", title: String.duplicate("title ", 20), listener: %{effective: :sync, requested: :steer, unread_count: 2}}

    layout =
      Layout.compute([summary], 140)
      |> Map.put(:latest_event_by_id, %{"42" => %{message: String.duplicate("latest ", 20)}})

    row = Table.render_row(summary, false, 140, layout, %{}) |> IO.iodata_to_binary()
    assert Text.visual_width(Text.strip_ansi(row)) == 140
    assert row =~ "Sync · next turn (req Steer · interrupts) / 2 unread"
  end

  test "unknown listener renders unavailable instead of a plausible default" do
    for listener <- [nil, :unavailable, %{}, %{requested: :async, effective: nil, unread_count: 3}] do
      summary = %{identifier: "42", title: "Working", listener: listener}
      row = Table.render_row(summary, true, 160, Layout.compute([summary], 160), %{}) |> IO.iodata_to_binary()
      assert row =~ "unavailable"
    end

    assert Listener.label(nil) == "unavailable / ? unread"
    assert Listener.label(%{}) == "unavailable / ? unread"
    assert Listener.label(%{requested: :async, unread_count: 3}) == "unavailable (req Async · pings only) / 3 unread"
  end

  test "column drops before the identifier and stays absent without listener data" do
    summary = %{identifier: "long-ticket-id", title: "Working", listener: %{effective: :sync, requested: :sync, unread_count: 7}}
    layout = Layout.compute([summary], 75)
    assert layout.listener_width == 0
    row = Table.render_row(summary, false, 75, layout, %{}) |> IO.iodata_to_binary()
    assert row =~ "long-ticket-id"
    refute row =~ "unread"
    legacy = Map.delete(summary, :listener)
    assert Layout.compute([legacy], 160).listener_width == 0
    refute Table.table_header_row(160, Layout.compute([legacy], 160)) |> IO.iodata_to_binary() =~ "LISTENER"
  end
end
