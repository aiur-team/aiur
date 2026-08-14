defmodule Aiur.Orchestrator.IssueSyncTest do
  # async: false — the dependency-gating tests inject AutoSubscriptions fns
  # through node-global persistent_term, so they cannot race other async cases.
  use ExUnit.Case, async: false

  alias Aiur.{AgentQueueStore, Issue, TrackerIdentity}
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Orchestrator.{AutoSubscriptions, IssueSync, State}

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
        fn _identity, pending? ->
          send(parent, {:terminal_verification_pending, pending?})
          :ok
        end
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
        fn _identity, pending? ->
          send(parent, {:terminal_verification_pending, pending?})
          :ok
        end
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

  describe "dependency transition event gating" do
    test "does not enqueue dependency_added when the auto-subscribe fails" do
      on_exit(fn -> AutoSubscriptions.set_add_subscription_fn(nil) end)

      issue_id = "sync-gating-#{System.unique_integer([:positive])}"
      blocker_id = "sync-blocker-#{System.unique_integer([:positive])}"
      identifier = "its-everdred/aiur##{issue_id}"
      blocker = %{id: blocker_id, identifier: blocker_id, state: "in-progress"}

      previous_issue = %{issue(issue_id, "in-progress") | blocked_by: []}
      current_issue = %{issue(issue_id, "in-progress") | blocked_by: [blocker]}
      on_exit(fn -> SubscriptionStore.stop(identifier) end)

      queue_store = AgentQueueStore.new()
      state = %State{last_polled_issues: %{issue_id => previous_issue}, queue_store: queue_store}

      # Force the subscribe step to fail: a dependency_added event must NOT be
      # enqueued behind a subscription that did not land (that is what leaves
      # a blockee never auto-resuming — the #1059 defect this gates).
      AutoSubscriptions.set_add_subscription_fn(fn _id, _topic, _reason ->
        {:error, :simulated_store_failure}
      end)

      result =
        IssueSync.sync_polled_issue_state(
          state,
          [current_issue],
          fn _ids -> {:ok, []} end,
          fn _identity, _lifecycle -> :ok end,
          MapSet.new(["done", "cancelled"]),
          fn _status -> :ok end,
          fn _identity, _pending? -> :ok end
        )

      dependency_items =
        result.queue_store.items
        |> Map.values()
        |> Enum.filter(&(&1.event_type == :dependency_added))

      assert dependency_items == []
      assert result.queue_store == queue_store
    end

    test "does not enqueue dependency_removed when the auto-unsubscribe fails" do
      on_exit(fn -> AutoSubscriptions.set_remove_subscription_fn(nil) end)

      issue_id = "sync-gating-rem-#{System.unique_integer([:positive])}"
      blocker_id = "sync-blocker-rem-#{System.unique_integer([:positive])}"
      identifier = "its-everdred/aiur##{issue_id}"
      blocker = %{id: blocker_id, identifier: blocker_id, state: "in-progress"}

      previous_issue = %{issue(issue_id, "in-progress") | blocked_by: [blocker]}
      current_issue = %{issue(issue_id, "in-progress") | blocked_by: []}
      on_exit(fn -> SubscriptionStore.stop(identifier) end)

      queue_store = AgentQueueStore.new()
      state = %State{last_polled_issues: %{issue_id => previous_issue}, queue_store: queue_store}

      AutoSubscriptions.set_remove_subscription_fn(fn _id, _topic, _reason ->
        {:error, :simulated_remove_failure}
      end)

      result =
        IssueSync.sync_polled_issue_state(
          state,
          [current_issue],
          fn _ids -> {:ok, []} end,
          fn _identity, _lifecycle -> :ok end,
          MapSet.new(["done", "cancelled"]),
          fn _status -> :ok end,
          fn _identity, _pending? -> :ok end
        )

      dependency_items =
        result.queue_store.items
        |> Map.values()
        |> Enum.filter(&(&1.event_type == :dependency_removed))

      assert dependency_items == []
      assert result.queue_store == queue_store
    end
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
