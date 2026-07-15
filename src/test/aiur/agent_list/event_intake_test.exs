defmodule Aiur.AgentList.EventIntakeTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.EventIntake

  defp state(debug? \\ false) do
    %{
      debug_events: [],
      debug_mode?: debug?
    }
  end

  test "non-debug intake does not become a second activity owner" do
    state =
      state()
      |> Map.merge(%{
        latest_event_by_id: %{"42" => :shared},
        progress_by_id: %{"42" => [{40, 1}]},
        phase_by_identifier: %{"42" => :work}
      })

    entry = %{kind: :publish, topic: "ticket.42.agent.progress", body: %{percent: 90}}

    assert EventIntake.fold(state, entry) == state
  end

  test "debug event ring caps at 200 newest first only in debug mode" do
    entries = for n <- 1..205, do: %{kind: :publish, topic: "ticket.#{n}.event", body: %{}}

    debug_state = Enum.reduce(entries, state(true), &EventIntake.fold(&2, &1))
    normal_state = Enum.reduce(entries, state(false), &EventIntake.fold(&2, &1))

    assert length(debug_state.debug_events) == 200
    assert hd(debug_state.debug_events).topic == "ticket.205.event"
    assert List.last(debug_state.debug_events).topic == "ticket.6.event"
    assert normal_state.debug_events == []
  end
end
