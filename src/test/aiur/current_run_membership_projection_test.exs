defmodule Aiur.CurrentRunMembership.ProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.CurrentRunMembership.Event
  alias Aiur.CurrentRunMembership.Projection
  alias Aiur.TrackerIdentity

  @run_id "run-membership-test"
  @now ~U[2026-07-14 12:00:00Z]

  test "keeps repository-qualified identities with the same issue number distinct" do
    state = Projection.new(@run_id)

    {:accepted, state} = Projection.apply(state, event(identity("owner-a", "repo-a", "I-1", "42"), :queued))
    {:accepted, state} = Projection.apply(state, event(identity("owner-b", "repo-b", "I-2", "42"), :queued))

    assert Enum.map(Projection.members(state), & &1.identity.provider_id) == ["I-1", "I-2"]
    assert state.generation == 2
  end

  test "retains terminal membership and rejects later nonterminal observations" do
    issue = identity()
    state = Projection.new(@run_id)

    {:accepted, state} = Projection.apply(state, event(issue, :running))
    {:accepted, state} = Projection.apply(state, event(issue, :completed, 1))
    {:ignored, :terminal, state} = Projection.apply(state, event(issue, :retrying, 2))

    assert %{lifecycle: :completed, terminal?: true} = Projection.member(state, issue)
    assert state.generation == 2
  end

  test "records every supported lifecycle observation as current-run membership" do
    lifecycles = [:queued, :retrying, :allocated, :running, :paused, :waiting, :replaced, :completed, :cancelled]

    state =
      lifecycles
      |> Enum.with_index(1)
      |> Enum.reduce(Projection.new(@run_id), fn {lifecycle, index}, state ->
        {:accepted, state} = Projection.apply(state, event(identity("owner", "repo", "I-#{index}", "#{index}"), lifecycle, index))
        state
      end)

    assert Enum.map(Projection.members(state), & &1.lifecycle) == lifecycles
    assert Enum.count(Projection.members(state), & &1.terminal?) == 2
  end

  test "deduplicates and ignores out-of-order observations during replay" do
    issue = identity()
    queued = event(issue, :queued)
    running = event(issue, :running, 2)
    stale = event(issue, :waiting, 1)

    assert {:ok, state} = Projection.replay(@run_id, [queued, queued, running, stale])

    assert %{lifecycle: :running, terminal?: false} = Projection.member(state, issue)
    assert state.generation == 2
  end

  test "does not advance the generation for a repeated lifecycle observation" do
    issue = identity()
    state = Projection.new(@run_id)
    {:accepted, state} = Projection.apply(state, event(issue, :waiting))
    {:ignored, :duplicate, state} = Projection.apply(state, event(issue, :waiting, 1))
    assert state.generation == 1
  end

  test "rejects unjoinable identities and records with forbidden source content" do
    assert {:error, :unjoinable_identity} = Event.new(@run_id, TrackerIdentity.unjoinable(:legacy), :queued, @now)

    assert {:error, :invalid_source} =
             Event.new(@run_id, identity(), :queued, @now, source: %{title: "must not persist"})
  end

  test "serializes and validates an event checksum without persisting issue content" do
    event = event(identity(), :paused)
    record = Event.to_record(event)

    assert {:ok, decoded} = Event.from_record(record)
    assert decoded == event

    assert {:error, :invalid_checksum} = Event.from_record(Map.put(record, "checksum", "not-the-original-checksum"))
    refute inspect(record) =~ "ticket title"
    refute Map.has_key?(record, "title")
    refute Map.has_key?(record, "workspace_path")
  end

  defp event(identity, lifecycle, seconds \\ 0) do
    {:ok, event} = Event.new(@run_id, identity, lifecycle, DateTime.add(@now, seconds, :second))
    event
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
