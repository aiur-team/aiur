defmodule Aiur.Orchestrator.IssueSyncTest do
  use ExUnit.Case, async: true

  alias Aiur.{Issue, TrackerIdentity}
  alias Aiur.Orchestrator.{IssueSync, State}

  test "ignores a non-list poll result" do
    state = %State{last_polled_issues: %{"42" => %{id: "42"}}}

    assert IssueSync.sync_polled_issue_state(state, :invalid) == state
  end

  test "records an idle completed ticket before an active-only poll drops it" do
    previous_issue = issue("42", "in-progress")

    state = %State{last_polled_issues: %{"42" => previous_issue}}
    parent = self()

    refreshed_state =
      IssueSync.sync_polled_issue_state(
        state,
        [],
        fn ["42"] -> {:ok, [%{previous_issue | state: "done"}]} end,
        fn identity, lifecycle ->
          send(parent, {:membership_observed, identity, lifecycle})
          :ok
        end,
        MapSet.new(["done", "cancelled"]),
        fn _status -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:membership_observed, %TrackerIdentity{provider_id: "node-42"}, :completed}
    assert refreshed_state.last_polled_issues == %{}
  end

  test "records an idle cancelled ticket before an active-only poll drops it" do
    previous_issue = issue("43", "in-progress")

    state = %State{last_polled_issues: %{"43" => previous_issue}}
    parent = self()

    refreshed_state =
      IssueSync.sync_polled_issue_state(
        state,
        [],
        fn ["43"] -> {:ok, [%{previous_issue | state: "cancelled"}]} end,
        fn identity, lifecycle ->
          send(parent, {:membership_observed, identity, lifecycle})
          :ok
        end,
        MapSet.new(["done", "cancelled"]),
        fn _status -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:membership_observed, %TrackerIdentity{provider_id: "node-43"}, :cancelled}
    assert refreshed_state.last_polled_issues == %{}
  end

  test "does not infer a terminal transition from an idle ticket's absence" do
    previous_issue = issue("44", "in-progress")
    state = %State{last_polled_issues: %{"44" => previous_issue}}
    parent = self()

    refreshed_state =
      IssueSync.sync_polled_issue_state(
        state,
        [],
        fn ["44"] -> {:ok, []} end,
        fn identity, lifecycle ->
          send(parent, {:membership_observed, identity, lifecycle})
          :ok
        end,
        MapSet.new(["done", "cancelled"]),
        fn _status -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    refute_receive {:membership_observed, _, _}
    assert refreshed_state.last_polled_issues == %{"44" => previous_issue}
  end

  test "retries an idle terminal verification after a transient by-id failure" do
    previous_issue = issue("45", "in-progress")
    state = %State{last_polled_issues: %{"45" => previous_issue}}
    parent = self()

    unavailable =
      IssueSync.sync_polled_issue_state(
        state,
        [],
        fn ["45"] -> {:error, :temporarily_unavailable} end,
        fn _identity, _lifecycle -> flunk("must not record membership before verification") end,
        MapSet.new(["done", "cancelled"]),
        fn :unavailable -> send(parent, :membership_freshness_unavailable) end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive :membership_freshness_unavailable
    assert unavailable.last_polled_issues == %{"45" => previous_issue}

    recovered =
      IssueSync.sync_polled_issue_state(
        unavailable,
        [],
        fn ["45"] -> {:ok, [%{previous_issue | state: "done"}]} end,
        fn identity, lifecycle ->
          send(parent, {:membership_observed, identity, lifecycle})
          :ok
        end,
        MapSet.new(["done", "cancelled"]),
        fn _status -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:membership_observed, %TrackerIdentity{provider_id: "node-45"}, :completed}
    assert recovered.last_polled_issues == %{}
  end

  test "retains a terminal ticket when membership persistence rejects its observation" do
    previous_issue = issue("46", "in-progress")
    state = %State{last_polled_issues: %{"46" => previous_issue}}
    parent = self()

    pending =
      IssueSync.sync_polled_issue_state(
        state,
        [],
        fn ["46"] -> {:ok, [%{previous_issue | state: "done"}]} end,
        fn _identity, _lifecycle -> {:error, :disk_full} end,
        MapSet.new(["done", "cancelled"]),
        fn status -> send(parent, {:freshness, status}) end,
        fn _identity, pending? -> send(parent, {:terminal_verification_pending, pending?}) end
      )

    assert_receive {:freshness, :unavailable}
    assert pending.last_polled_issues == %{"46" => previous_issue}

    resolved =
      IssueSync.sync_polled_issue_state(
        pending,
        [],
        fn ["46"] -> {:ok, [%{previous_issue | state: "done"}]} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done", "cancelled"]),
        fn _status -> :ok end,
        fn _identity, pending? -> send(parent, {:terminal_verification_pending, pending?}) end
      )

    assert resolved.last_polled_issues == %{}
  end

  test "isolates an unavailable projection marker while retaining terminal verification" do
    previous_issue = issue("47", "in-progress")
    state = %State{last_polled_issues: %{"47" => previous_issue}}
    parent = self()

    result =
      IssueSync.sync_polled_issue_state(
        state,
        [],
        fn ["47"] -> {:error, :temporarily_unavailable} end,
        fn _identity, _lifecycle -> flunk("must not observe without a tracker result") end,
        MapSet.new(["done", "cancelled"]),
        fn :unavailable -> exit(:noproc) end,
        fn _identity, pending? -> send(parent, {:terminal_verification_pending, pending?}) end
      )

    assert result.last_polled_issues == %{"47" => previous_issue}
  end

  test "chunks disappearing idle verification across polls" do
    previous_issues =
      for id <- 1..250, into: %{}, do: {Integer.to_string(id), issue(Integer.to_string(id), "in-progress")}

    parent = self()
    state = %State{last_polled_issues: previous_issues}

    result =
      IssueSync.sync_polled_issue_state(
        state,
        [],
        fn ids ->
          send(parent, {:verified_ids, ids})
          {:ok, []}
        end,
        fn _identity, _lifecycle -> flunk("absent tickets cannot be inferred terminal") end,
        MapSet.new(["done", "cancelled"]),
        fn _status -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:verified_ids, ids}
    assert length(ids) == 25
    assert map_size(result.last_polled_issues) == 250
  end

  defp issue(id, state) do
    %Issue{
      id: id,
      identifier: "its-everdred/aiur##{id}",
      state: state,
      tracker_identity: %TrackerIdentity{
        version: 1,
        status: :joinable,
        kind: :github,
        owner: "its-everdred",
        repository: "aiur",
        provider_id: "node-#{id}",
        identifier: id,
        reason: nil
      }
    }
  end
end
