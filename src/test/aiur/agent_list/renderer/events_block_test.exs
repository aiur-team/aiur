defmodule Aiur.AgentList.Renderer.EventsBlockTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.Renderer.{EventsBlock, Text}

  defp render(iodata), do: iodata |> IO.iodata_to_binary() |> Text.strip_ansi()

  test "events_block collapses when budget or width is too small" do
    assert EventsBlock.events_block(%{debug_events: [%{}]}, 40, 1) == {[], 0}
    assert EventsBlock.events_block(%{debug_events: [%{}]}, 3, 3) == {[], 0}
  end

  test "events_block uses full budget and pads empty rows above events" do
    state = %{debug_events: [%{kind: :publish, topic: "ticket.2.branch.push"}]}

    {iodata, count} = EventsBlock.events_block(state, 40, 4)
    output = render(iodata)

    assert count == 4
    assert output =~ "│                                      │\r\n│                                      │\r\n│ 💬 2 pushed"
  end

  test "suppressed self-echo entries do not consume capacity" do
    state = %{
      summaries: [%{identifier: "830"}],
      selection_index: 0,
      debug_events: [
        %{kind: :receive, topic: "ticket.830.agent.phase.work.start", identifier: "830"},
        %{kind: :publish, topic: "ticket.2.branch.push"},
        %{kind: :publish, topic: "ticket.1.branch.push"}
      ]
    }

    {iodata, 3} = EventsBlock.events_block(state, 50, 3)
    output = render(iodata)

    assert output =~ "💬 1 pushed"
    assert output =~ "💬 2 pushed"
    refute output =~ "started work"
  end

  test "events_divider_row labels oldest only when width allows it" do
    assert EventsBlock.events_divider_row(40) |> render() =~ "oldest"
    assert EventsBlock.events_divider_row(10) |> render() == "├────────┤"
  end
end
