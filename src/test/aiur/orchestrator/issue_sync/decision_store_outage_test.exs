defmodule Aiur.Orchestrator.IssueSync.DecisionStoreOutageTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State

  describe "DecisionStore outage alert (#2453)" do
    setup do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.decision_store_unavailable")
      :ok = Exchange.subscribe("system.dispatch.decision_store_unavailable.resolved")
      :ok = Exchange.subscribe("system.dispatch.capacity_starved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      :ok
    end

    test "raises exactly one needs-attention alert when the DecisionStore is unreachable with work queued" do
      ready = issue("store-outage", "todo")

      state = %State{
        max_concurrent_agents: 4,
        effective_concurrent_agents: 4,
        blocked_ticket_ids: :unavailable
      }

      waiting = IssueSync.sync_decision_store_unavailable_alert(state, [ready], 1_000)
      assert waiting.decision_store_unavailable_since_ms == 1_000
      refute waiting.decision_store_unavailable_alert_active
      mailbox_barrier()
      refute_received {:event, %{topic: "system.dispatch.decision_store_unavailable"}}

      alerted = IssueSync.sync_decision_store_unavailable_alert(waiting, [ready], 61_000)
      assert alerted.decision_store_unavailable_alert_active
      refute alerted.decision_store_unavailable_alert_resolution_emitted

      assert_received {:event, %{topic: "system.dispatch.decision_store_unavailable"} = event}
      assert event["needs_attention"] == true
      assert event["reason"] =~ "DecisionStore could not be read"
      assert event["reason"] =~ "capacity-starvation alerting is suppressed"

      # Held across further polls without re-publishing.
      repeated = IssueSync.sync_decision_store_unavailable_alert(alerted, [ready], 122_000)
      assert repeated == alerted
      mailbox_barrier()
      refute_received {:event, %{topic: "system.dispatch.decision_store_unavailable"}}

      # The fail-closed dispatch behaviour is untouched by this ticket.
      assert DispatchPolicy.blocked_on_decision?(ready, :unavailable)
    end

    test "a brief unavailability shorter than the dwell raises nothing" do
      ready = issue("store-blip", "todo")

      state = %State{
        max_concurrent_agents: 4,
        effective_concurrent_agents: 4,
        blocked_ticket_ids: :unavailable
      }

      first = IssueSync.sync_decision_store_unavailable_alert(state, [ready], 1_000)
      within_dwell = IssueSync.sync_decision_store_unavailable_alert(first, [ready], 5_000)

      refute within_dwell.decision_store_unavailable_alert_active
      mailbox_barrier()
      refute_received {:event, %{topic: "system.dispatch.decision_store_unavailable"}}

      # A store that recovers before the dwell ends resolves with no alert pair.
      recovered = %{within_dwell | blocked_ticket_ids: MapSet.new()}
      _cleared = IssueSync.sync_decision_store_unavailable_alert(recovered, [ready], 6_000)
      refute_received {:event, %{topic: "system.dispatch.decision_store_unavailable.resolved"}}
    end

    test "does not raise while the store is down but no dispatchable work is queued" do
      ready = issue("store-idle", "todo")

      state = %State{
        max_concurrent_agents: 4,
        effective_concurrent_agents: 4,
        blocked_ticket_ids: :unavailable
      }

      # The queued ticket is claimed, so nothing is dispatchable: an idle fleet
      # on a store outage has no capacity-starvation signal to suppress.
      claimed = %{state | claimed: MapSet.new([ready.id])}

      waiting = IssueSync.sync_decision_store_unavailable_alert(claimed, [ready], 1_000)
      no_work = IssueSync.sync_decision_store_unavailable_alert(waiting, [ready], 61_000)

      refute no_work.decision_store_unavailable_alert_active
      assert is_nil(no_work.decision_store_unavailable_since_ms)
      mailbox_barrier()
      refute_received {:event, %{topic: "system.dispatch.decision_store_unavailable"}}
    end

    test "resolves on recovery and normal capacity alerting resumes" do
      ready = issue("store-recovery", "todo")

      alerted =
        %State{
          max_concurrent_agents: 4,
          effective_concurrent_agents: 4,
          blocked_ticket_ids: :unavailable
        }
        |> IssueSync.sync_decision_store_unavailable_alert([ready], 1_000)
        |> IssueSync.sync_decision_store_unavailable_alert([ready], 61_000)

      assert alerted.decision_store_unavailable_alert_active
      assert_received {:event, %{topic: "system.dispatch.decision_store_unavailable"}}

      # The store recovers: `blocked_ticket_ids` is a fresh MapSet again.
      recovered = %{alerted | blocked_ticket_ids: MapSet.new()}

      cleared = IssueSync.sync_decision_store_unavailable_alert(recovered, [ready], 62_000)
      refute cleared.decision_store_unavailable_alert_active
      assert cleared.decision_store_unavailable_alert_resolution_emitted
      assert is_nil(cleared.decision_store_unavailable_since_ms)
      assert_received {:event, %{topic: "system.dispatch.decision_store_unavailable.resolved"}}

      # With the gate lifted, queued work is visible to the capacity-starvation
      # alert again: a genuine load gate now raises the normal dispatch alert,
      # so a recovered store can never leave capacity alerting suppressed.
      starved = %{
        cleared
        | dispatch_capacity_constraints: [%{kind: :load, detail: "load=24.0 threshold=1.0 schedulers=8"}]
      }

      _ =
        starved
        |> IssueSync.sync_capacity_starvation_alert([ready], 63_000)
        |> IssueSync.sync_capacity_starvation_alert([ready], 123_000)

      assert_received {:event, %{topic: "system.dispatch.capacity_starved"} = event}
      assert event["reason"] =~ "load gate"
      assert event["reason"] =~ "Ready tickets=1"
    end

    test "rearms after a recovery so a second outage raises again" do
      ready = issue("store-rearm", "todo")

      alerted =
        %State{
          max_concurrent_agents: 4,
          effective_concurrent_agents: 4,
          blocked_ticket_ids: :unavailable
        }
        |> IssueSync.sync_decision_store_unavailable_alert([ready], 1_000)
        |> IssueSync.sync_decision_store_unavailable_alert([ready], 61_000)

      assert_received {:event, %{topic: "system.dispatch.decision_store_unavailable"}}

      cleared =
        %{alerted | blocked_ticket_ids: MapSet.new()}
        |> IssueSync.sync_decision_store_unavailable_alert([ready], 62_000)

      assert_received {:event, %{topic: "system.dispatch.decision_store_unavailable.resolved"}}

      # Second outage, fresh dwell, raises again exactly once.
      waiting =
        %{cleared | blocked_ticket_ids: :unavailable}
        |> IssueSync.sync_decision_store_unavailable_alert([ready], 100_000)

      _rearmed =
        waiting
        |> IssueSync.sync_decision_store_unavailable_alert([ready], 160_000)

      assert_received {:event, %{topic: "system.dispatch.decision_store_unavailable"}}
    end
  end
end
