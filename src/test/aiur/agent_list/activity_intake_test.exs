defmodule Aiur.AgentList.ActivityIntakeTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.{ActivityIntake, State}
  alias Aiur.TrackerIdentity

  @now ~U[2026-07-15 12:00:00Z]

  test "joins activity through trusted repository-qualified identity" do
    selected = identity("one", "repo", "I-42", "42")
    other = identity("two", "repo", "I-42", "42")

    state =
      state([summary("42", selected)])
      |> ActivityIntake.load(%{
        generation: 3,
        entries: [activity(selected, 40, :work), activity(other, 90, :review)]
      })

    assert [{40, _timestamp}] = state.progress_by_id["42"]
    assert state.phase_by_identifier == %{"42" => :work}
    assert state.latest_event_by_id["42"].message == "Progress 40%"
    assert state.activity_status_by_identifier["42"].snapshot == :fresh
  end

  test "unknown activity stays unknown and never becomes zero or complete" do
    ticket = identity()

    state =
      state([summary("42", ticket, :deactivated)])
      |> ActivityIntake.load(%{
        generation: 0,
        entries: [
          %{
            identity: ticket,
            status: :fresh,
            progress: %{status: :unknown},
            stage: %{status: :unknown},
            latest_evidence: %{status: :unknown}
          }
        ]
      })

    assert state.progress_by_id == %{}
    assert state.phase_by_identifier == %{}
    assert state.latest_event_by_id == %{}

    assert state.activity_status_by_identifier["42"] == %{
             snapshot: :fresh,
             progress: :unknown,
             stage: :unknown,
             evidence: :unknown
           }
  end

  test "stale stage is not presented as active and stale evidence is explicit" do
    ticket = identity()
    stale = activity(ticket, 65, :review, :stale)

    state = ActivityIntake.load(state([summary("42", ticket)]), %{generation: 0, entries: [stale]})

    assert state.phase_by_identifier == %{}
    assert [{65, _timestamp}] = state.progress_by_id["42"]
    assert state.latest_event_by_id["42"].stale?
    assert state.activity_status_by_identifier["42"].progress == :stale
  end

  test "exact generations apply once, gaps reload, and a new attempt resets samples" do
    ticket = identity()
    initial = activity(ticket, 40, :work)

    state = ActivityIntake.load(state([summary("42", ticket)]), %{generation: 0, entries: [initial]})
    next = activity(ticket, 60, :review)

    assert {:ok, state} =
             ActivityIntake.fold(state, %{generation: 1, identity: ticket, snapshot: next})

    assert [{60, _}, {40, _}] = state.progress_by_id["42"]

    assert {:ok, duplicate} =
             ActivityIntake.fold(state, %{
               generation: 1,
               identity: ticket,
               snapshot: activity(ticket, 10, :plan)
             })

    assert duplicate.progress_by_id == state.progress_by_id
    assert :reload = ActivityIntake.fold(state, %{generation: 3, identity: ticket, snapshot: next})

    assert :reload =
             ActivityIntake.fold(state, %{
               generation: 2,
               identity: ticket,
               snapshot: %{next | identity: identity("other", "repo", "I-42", "42")}
             })

    restarted = put_in(next, [:progress, :provenance, :attempt], 2)
    assert {:ok, reset} = ActivityIntake.fold(state, %{generation: 2, identity: ticket, snapshot: restarted})
    assert [{60, _}] = reset.progress_by_id["42"]
  end

  test "same-percent evidence refreshes its presentation timestamp without duplicating samples" do
    ticket = identity()
    initial = activity(ticket, 40, :work)
    state = ActivityIntake.load(state([summary("42", ticket)]), %{generation: 0, entries: [initial]})

    refreshed =
      initial
      |> put_in([:progress, :observed_at], DateTime.add(@now, 10, :second))
      |> put_in([:latest_evidence, :observed_at], DateTime.add(@now, 10, :second))

    assert {:ok, state} =
             ActivityIntake.fold(state, %{generation: 1, identity: ticket, snapshot: refreshed})

    assert [{40, _timestamp}] = state.progress_by_id["42"]
  end

  defp state(summaries) do
    State.new(command_template: "cmd")
    |> Map.put(:summaries, summaries)
  end

  defp summary(identifier, identity, work_state \\ :working) do
    %{
      identifier: identifier,
      status: :running,
      work_state: work_state,
      tracker_identity: identity
    }
  end

  defp activity(identity, percent, stage, freshness \\ :fresh) do
    %{
      identity: identity,
      status: freshness,
      progress: %{
        status: :known,
        freshness: freshness,
        percent: percent,
        observed_at: @now,
        provenance: %{run_id: "run-1", attempt: 1, session_id: "session-1"}
      },
      stage: %{status: :known, freshness: freshness, value: stage, observed_at: @now},
      latest_evidence: %{
        status: :known,
        source: %{kind: :agent_event, name: "progress"},
        attributes: %{percent: percent},
        observed_at: @now
      }
    }
  end

  defp identity(owner \\ "owner", repository \\ "repo", provider_id \\ "I-42", identifier \\ "42") do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: owner,
      repository: repository,
      provider_id: provider_id,
      identifier: identifier,
      reason: nil
    }
  end
end
