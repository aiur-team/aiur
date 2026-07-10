defmodule Aiur.AgentList.EventIntakeTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.EventIntake

  defp state(debug? \\ false) do
    %{
      latest_event_by_id: %{},
      progress_by_id: %{},
      phase_by_identifier: %{},
      debug_events: [],
      debug_mode?: debug?
    }
  end

  test "latest event records publish entries on ticket topics only" do
    publish = %{kind: :publish, topic: "ticket.42.branch.push", body: %{message: "pushed"}}
    receive = %{kind: :receive, topic: "ticket.42.branch.push", body: %{message: "received"}}
    read = %{kind: :read, topic: "ticket.42.branch.push", body: %{message: "read"}}
    system = %{kind: :publish, topic: "system.branch.push", body: %{message: "system"}}

    folded =
      state()
      |> EventIntake.fold(receive)
      |> EventIntake.fold(read)
      |> EventIntake.fold(system)
      |> EventIntake.fold(publish)

    assert %{message: "pushed", topic: "ticket.42.branch.push"} = folded.latest_event_by_id["42"]
  end

  test "latest event message prefers body message and falls back to topic verb" do
    with_message = EventIntake.fold(state(), %{kind: :publish, topic: "ticket.42.branch.push", body: %{"message" => "hi"}})
    without_message = EventIntake.fold(state(), %{kind: :publish, topic: "ticket.7.branch.push", body: %{}})

    assert with_message.latest_event_by_id["42"].message == "hi"
    assert without_message.latest_event_by_id["7"].message == "branch push"
  end

  test "progress checkin can lower while phase and bare topics ratchet" do
    initial =
      state()
      |> EventIntake.fold(%{kind: :publish, topic: "ticket.42.agent.progress", body: %{percent: 50}})
      |> EventIntake.fold(%{kind: :publish, topic: "ticket.42.agent.progress.phase", body: %{percent: 40}})

    assert [{50, _}] = initial.progress_by_id["42"]

    lowered =
      EventIntake.fold(initial, %{
        kind: :publish,
        topic: "ticket.42.agent.progress.checkin",
        body: %{percent: 30}
      })

    assert [{30, _} | _] = lowered.progress_by_id["42"]

    raised =
      EventIntake.fold(lowered, %{
        kind: :publish,
        topic: "ticket.42.agent.progress.phase",
        body: %{"percent" => 70.9}
      })

    assert [{70, _} | _] = raised.progress_by_id["42"]
  end

  test "phase start sets matching end clears and stale end leaves newer phase" do
    folded =
      state()
      |> EventIntake.fold(%{kind: :publish, topic: "ticket.42.agent.phase.plan.start", body: %{}})
      |> EventIntake.fold(%{kind: :publish, topic: "ticket.42.agent.phase.work.start", body: %{}})
      |> EventIntake.fold(%{kind: :publish, topic: "ticket.42.agent.phase.plan.end", body: %{}})

    assert folded.phase_by_identifier["42"] == :work

    cleared = EventIntake.fold(folded, %{kind: :publish, topic: "ticket.42.agent.phase.work.end", body: %{}})
    refute Map.has_key?(cleared.phase_by_identifier, "42")
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
