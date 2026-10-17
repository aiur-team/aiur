defmodule Aiur.Orchestrator.Status.ProgressAndIdentityTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorStatusSupport

  alias Aiur.AgentPubSub
  alias Aiur.DecisionStore
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.TicketActivity
  alias Aiur.TicketActivity.Projection
  alias Aiur.TrackerIdentity

  test "orchestrator snapshot includes retry backoff entries" do
    orchestrator_name = Module.concat(__MODULE__, :RetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    retry_entry = %{
      attempt: 2,
      timer_ref: nil,
      due_at_ms: System.monotonic_time(:millisecond) + 5_000,
      identifier: "MT-500",
      error: "agent exited: :boom"
    }

    initial_state = :sys.get_state(pid)
    new_state = %{initial_state | retry_attempts: %{"mt-500" => retry_entry}}
    :sys.replace_state(pid, fn _ -> new_state end)

    snapshot = GenServer.call(pid, :snapshot)
    assert is_list(snapshot.retrying)

    assert [
             %{
               issue_id: "mt-500",
               attempt: 2,
               due_in_ms: due_in_ms,
               identifier: "MT-500",
               error: "agent exited: :boom",
               priority: nil,
               progress_percent: nil,
               progress_freshness: :unknown
             }
           ] = snapshot.retrying

    assert due_in_ms > 0

    # No issue was ever polled for "mt-500", so its upstream list is unknown
    # rather than empty. `nil` is what makes the Stream Deck render the key
    # `Blocked`; an `[]` here would read as "no dependencies" and render it
    # `Unblocked` off data we never resolved.
    assert [%{blocked_by: nil}] = snapshot.retrying
  end

  test "snapshot retains a stale progress reading instead of a zero nobody measured" do
    identity = tracker_identity("2001")
    observed_at = DateTime.add(DateTime.utc_now(), -5, :second)

    install_activity_projection(activity_projection(identity, 70, observed_at: observed_at, stale_after_ms: 1))

    pid = orchestrator_running_only("issue-stale-progress", "2001", identity)

    assert %{running: [%{progress_percent: 70, progress_freshness: :stale}]} = GenServer.call(pid, :snapshot)
  end

  test "snapshot reports a never-observed ticket as unknown progress" do
    identity = tracker_identity("2002")

    install_activity_projection(Projection.new())

    pid = orchestrator_running_only("issue-unobserved-progress", "2002", identity)

    assert %{running: [%{progress_percent: nil, progress_freshness: :unknown}]} = GenServer.call(pid, :snapshot)
  end

  test "snapshot keeps a fresh progress reading fresh" do
    identity = tracker_identity("2003")

    install_activity_projection(activity_projection(identity, 40))

    pid = orchestrator_running_only("issue-fresh-progress", "2003", identity)

    assert %{running: [%{progress_percent: 40, progress_freshness: :fresh}]} = GenServer.call(pid, :snapshot)
  end

  test "snapshot rounds a float progress reading rather than discarding it" do
    identity = tracker_identity("2004")

    projection =
      identity
      |> activity_projection(70)
      |> put_progress_percent(70.5)

    install_activity_projection(projection)

    pid = orchestrator_running_only("issue-float-progress", "2004", identity)

    assert %{running: [%{progress_percent: 71, progress_freshness: :fresh}]} = GenServer.call(pid, :snapshot)
  end

  test "an unreachable activity projection reports unknown progress rather than zeroing the fleet" do
    identity = tracker_identity("2005")

    install_activity_projection(activity_projection(identity, 80))

    pid = orchestrator_running_only("issue-unreachable-progress", "2005", identity)

    on_exit(fn -> :sys.resume(TicketActivity) end)
    :sys.suspend(TicketActivity)

    assert %{running: [%{progress_percent: nil, progress_freshness: :unknown}]} = GenServer.call(pid, :snapshot)
  end

  test "status API, snapshot, and PubSub retain exact tracker identities" do
    orchestrator_name = Module.concat(__MODULE__, :TrackerIdentityOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    running_identity = tracker_identity("MT-701")
    retry_identity = tracker_identity("MT-702")
    idle_identity = tracker_identity("MT-703")

    running =
      "issue-running"
      |> running_entry("MT-701", :working)
      |> put_in([:issue, Access.key(:tracker_identity)], running_identity)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{"issue-running" => running},
          retry_attempts: %{
            "issue-retrying" => %{
              attempt: 1,
              timer_ref: nil,
              due_at_ms: System.monotonic_time(:millisecond) + 5_000,
              identifier: "MT-702",
              tracker_identity: retry_identity
            }
          },
          last_polled_issues: %{
            "issue-running" => %Issue{
              id: "issue-running",
              identifier: "MT-701",
              state: "in-progress",
              tracker_identity: running_identity
            },
            "issue-retrying" => %Issue{
              id: "issue-retrying",
              identifier: "MT-702",
              state: "in-progress",
              tracker_identity: retry_identity
            },
            "issue-idle" => %Issue{
              id: "issue-idle",
              identifier: "MT-703",
              state: "todo",
              tracker_identity: idle_identity
            }
          }
      }
    end)

    snapshot = Orchestrator.snapshot(orchestrator_name, 5_000)
    assert [%{tracker_identity: ^running_identity}] = snapshot.running
    assert [%{tracker_identity: ^retry_identity}] = snapshot.retrying
    assert [%{tracker_identity: ^idle_identity}] = snapshot.idle

    assert %{tracker_identity: ^running_identity} =
             Enum.find(Orchestrator.status(orchestrator_name, 5_000), &(&1.identifier == "MT-701"))

    assert %{tracker_identity: ^retry_identity} =
             Enum.find(Orchestrator.status(orchestrator_name, 5_000), &(&1.identifier == "MT-702"))

    assert %{tracker_identity: ^idle_identity} =
             Enum.find(Orchestrator.status(orchestrator_name, 5_000), &(&1.identifier == "MT-703"))

    :ok = AgentPubSub.subscribe_running()
    :ok = StatusReport.notify_dashboard(:sys.get_state(pid))
    assert_receive {:running_changed, summaries}, 1000

    assert %{tracker_identity: ^running_identity} =
             Enum.find(summaries, &(&1.identifier == "MT-701"))

    assert %{tracker_identity: ^retry_identity} =
             Enum.find(summaries, &(&1.identifier == "MT-702"))

    assert %{tracker_identity: ^idle_identity} =
             Enum.find(summaries, &(&1.identifier == "MT-703"))
  end

  test "status snapshots do not overwrite current identity from a same-number retry" do
    orchestrator_name = Module.concat(__MODULE__, :IdentityCollisionOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    retry_identity = tracker_identity("42")

    current_identity =
      TrackerIdentity.unjoinable(:repository_mismatch,
        owner: "owner",
        repository: "repo",
        identifier: 42
      )

    legacy_identity = TrackerIdentity.unjoinable(:legacy, identifier: 42)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | retry_attempts: %{
            "issue-retrying" => %{
              attempt: 1,
              timer_ref: nil,
              due_at_ms: System.monotonic_time(:millisecond) + 5_000,
              identifier: "42",
              tracker_identity: retry_identity
            }
          },
          last_polled_issues: %{
            "issue-retrying" => %Issue{
              id: "issue-retrying",
              identifier: "42",
              state: "in-progress",
              tracker_identity: current_identity
            },
            "legacy-42" => %Issue{
              id: "legacy-42",
              identifier: "42",
              state: "todo",
              tracker_identity: legacy_identity
            }
          }
      }
    end)

    snapshot = Orchestrator.snapshot(orchestrator_name, 5_000)
    assert [%{tracker_identity: ^current_identity}] = snapshot.retrying
    assert [%{issue_id: "legacy-42", tracker_identity: ^legacy_identity}] = snapshot.idle

    statuses = Orchestrator.status(orchestrator_name, 5_000)

    assert %{tracker_identity: ^current_identity} =
             Enum.find(statuses, &(&1.issue_id == "issue-retrying"))

    assert %{tracker_identity: ^legacy_identity} =
             Enum.find(statuses, &(&1.issue_id == "legacy-42"))
  end

  test "orchestrator snapshot includes idle rows and explicit waiting reasons" do
    orchestrator_name = Module.concat(__MODULE__, :FleetStateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    stale_entry =
      "issue-stale"
      |> running_entry("MT-600", :working)
      |> Map.put(:last_codex_timestamp, DateTime.add(DateTime.utc_now(), -10 * 24 * 60 * 60, :second))
      |> Map.merge(%{codex_app_server_pid: nil, last_codex_message: nil, last_codex_event: nil})

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{"issue-stale" => stale_entry},
          retry_attempts: %{
            "issue-retrying" => %{
              attempt: 1,
              timer_ref: nil,
              due_at_ms: System.monotonic_time(:millisecond) + 5_000,
              identifier: "MT-602"
            }
          },
          last_polled_issues: %{
            "issue-stale" => %Issue{id: "issue-stale", identifier: "MT-600", state: "In Progress"},
            "issue-ci-wait" => %Issue{
              id: "issue-ci-wait",
              identifier: "MT-601",
              state: "ci-wait",
              title: "Waiting on CI"
            },
            "issue-retrying" => %Issue{id: "issue-retrying", identifier: "MT-602", state: "In Progress"}
          }
      }
    end)

    snapshot = Orchestrator.snapshot(orchestrator_name, 5_000)

    assert [%{identifier: "MT-600", waiting_reason: :unresponsive, stale_for_seconds: stale_for_seconds}] =
             snapshot.running

    assert stale_for_seconds > 24 * 60 * 60

    # A tracker-active issue already shown in the retry-backoff bucket must
    # not also double up as an idle row.
    assert [%{identifier: "MT-601", state: "ci-wait", waiting_reason: :waiting_for_ci}] = snapshot.idle
  end

  test "orchestrator snapshot reads open decisions without calling the per-ticket store" do
    identifier = "MT-ATTENTION-#{System.unique_integer([:positive])}"
    issue_id = "issue-attention-#{System.unique_integer([:positive])}"
    orchestrator_name = Module.concat(__MODULE__, :NonblockingFleetStateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      SubscriptionStore.stop(identifier)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :ok = SubscriptionStore.attach(identifier)
    :ok = SubscriptionStore.add_attention(identifier, "operator-decision")
    assert {:ok, %{decision: decision}} = DecisionStore.request(%{"question" => "Which acceptance boundary applies?", "blocking" => true}, ticket: %{identifier: identifier})
    on_exit(fn -> DecisionStore.expire(decision.decision_id, "agent_not_running") end)
    [{store_pid, 1}] = Registry.lookup(Aiur.Events.SubscriptionStoreRegistry, identifier)

    entry =
      issue_id
      |> running_entry(identifier, :working)
      |> Map.merge(%{
        codex_app_server_pid: nil,
        last_codex_timestamp: DateTime.add(DateTime.utc_now(), -10 * 24 * 60 * 60, :second),
        last_codex_message: nil,
        last_codex_event: nil
      })

    :sys.replace_state(pid, fn state -> %{state | running: %{issue_id => entry}} end)
    :ok = :sys.suspend(store_pid)

    try do
      assert %{running: [row]} = Orchestrator.snapshot(orchestrator_name, 5_000)
      assert row.open_decision_count == 1
      assert row.waiting_reason == :waiting_for_human
    after
      :ok = :sys.resume(store_pid)
    end
  end
end
