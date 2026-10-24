defmodule Aiur.Orchestrator.IssueSync.ContradictoryLabelsTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.AlertFeed
  alias Aiur.AlertLedger
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State

  describe "reconcile_contradictory_state_labels (#2075)" do
    test "heals a polled ticket carrying todo+rework to the resolved single state" do
      dual = %{issue("dual", "todo") | state_labels: ["todo", "rework"]}
      parent = self()

      {healed_state, healed_issues} =
        IssueSync.reconcile_contradictory_state_labels(
          %State{},
          [dual],
          fn identifier, target ->
            send(parent, {:heal, identifier, target})
            :ok
          end
        )

      # `todo` wins the pair (a ticket that is also `todo` has no work for a
      # `rework` verdict to mean anything about), and the winner is written
      # through the tracker so GitHub stops carrying both labels.
      assert_receive {:heal, "its-everdred/aiur#dual", "todo"}, 1000

      assert [healed] = healed_issues
      assert healed.state == "todo"
      assert healed.state_labels == ["todo"]
      assert healed_state.last_polled_issues[dual.id].state == "todo"
    end

    test "keeps valid reason modifiers while healing workflow states (regression guard)" do
      dual = %{
        issue("dual-reasons", "todo")
        | state_labels: ["todo", "rework"],
          labels: ["agent:ci-red", "agent:merge-queued"]
      }

      {_state, [healed]} =
        IssueSync.reconcile_contradictory_state_labels(
          %State{},
          [dual],
          fn _identifier, _target -> :ok end
        )

      assert healed.state_labels == ["todo"]
      assert healed.labels == ["agent:ci-red", "agent:merge-queued"]
    end

    test "keeps the resolved issue dispatchable even when the heal write fails" do
      dual = %{issue("dual", "todo") | state_labels: ["todo", "rework"]}

      {healed_state, healed_issues} =
        IssueSync.reconcile_contradictory_state_labels(
          %State{},
          [dual],
          fn _id, _target -> {:error, :unavailable} end
        )

      assert [healed] = healed_issues
      assert healed.state == "todo"
      assert healed.state_labels == ["todo"]

      # A failed heal write must not strand the ticket this cycle: it stays
      # dispatchable on the resolved state and the next poll retries the heal.
      assert healed_state.last_polled_issues == %{}
    end

    test "emits one fleet alert for tickets undispatchable due to contradictory labels" do
      dual_a = %{issue("dual-a", nil) | state_labels: ["ci-wait", "rework"]}
      dual_b = %{issue("dual-b", nil) | state_labels: ["ci-wait", "human-review"]}

      now_ms = System.monotonic_time(:millisecond)

      state = %State{
        contradictory_state_label_tickets: %{
          dual_a.id => %{identifier: dual_a.identifier, labels: ["ci-wait", "rework"], since_ms: now_ms - 120_000},
          dual_b.id => %{identifier: dual_b.identifier, labels: ["ci-wait", "human-review"], since_ms: now_ms - 120_000}
        }
      }

      {healed_state, _healed} =
        IssueSync.reconcile_contradictory_state_labels(
          state,
          [dual_a, dual_b],
          fn _id, _target -> :ok end
        )

      # One actionable line names the whole undispatchable set instead of one
      # buried warning per ticket (#2366).
      assert healed_state.contradictory_state_label_alert_active
      assert map_size(healed_state.contradictory_state_label_tickets) == 2

      assert Enum.any?(
               AlertFeed.list(ledger_paths: [AlertLedger.path()], needs_attention: true),
               &(&1["topic"] == "system.fleet.contradictory_state_labels" and
                   &1["message"] =~ "2 tickets undispatchable due to contradictory labels")
             )

      # The line names each ticket's label pair, so the Executor can see which
      # state to drop without re-reading every ticket (#5796).
      assert [alert | _] =
               AlertFeed.list(ledger_paths: [AlertLedger.path()], needs_attention: true)
               |> Enum.filter(&(&1["topic"] == "system.fleet.contradictory_state_labels"))

      assert alert["message"] =~ "#{dual_a.identifier} (ci-wait+rework)"
      assert alert["message"] =~ "#{dual_b.identifier} (ci-wait+human-review)"
    end

    test "resolves the fleet alert once every ticket carries a single state label" do
      dual = %{issue("dual-c", nil) | state_labels: ["ci-wait", "rework"]}

      now_ms = System.monotonic_time(:millisecond)

      state = %State{
        contradictory_state_label_tickets: %{
          dual.id => %{identifier: dual.identifier, labels: ["ci-wait", "rework"], since_ms: now_ms - 120_000}
        },
        contradictory_state_label_alert_active: true
      }

      {healed_state, _healed} =
        IssueSync.reconcile_contradictory_state_labels(state, [], fn _id, _target -> :ok end)

      assert healed_state.contradictory_state_label_tickets == %{}
      assert healed_state.contradictory_state_label_alert_active == false

      assert Enum.any?(
               AlertFeed.list(ledger_paths: [AlertLedger.path()]),
               &(&1["topic"] == "system.fleet.contradictory_state_labels.resolved")
             )
    end

    test "heals a done+rework pair to rework so the ticket is not closed" do
      # #2437: the terminal `done` must never win a contradiction. A ticket
      # carrying `done` + `rework` heals to `rework` (the outstanding work),
      # never to `done` — healing to `done` would route the tracker write into
      # the terminal close path (`swap_and_maybe_close_issue/4`) and silently
      # discard the rework. `rework` is non-terminal, so the write only swaps
      # the label and the ticket stays open.
      dual = %{issue("dual-done-rework", nil) | state_labels: ["done", "rework"]}
      parent = self()

      {healed_state, healed_issues} =
        IssueSync.reconcile_contradictory_state_labels(
          %State{},
          [dual],
          fn identifier, target ->
            send(parent, {:heal, identifier, target})
            :ok
          end
        )

      assert_receive {:heal, "its-everdred/aiur#dual-done-rework", "rework"}, 1000

      # Assert the healed issue state, not just the label set: the winner is
      # written through the tracker, and a non-terminal target is what keeps
      # the ticket from being closed.
      assert [healed] = healed_issues
      assert healed.state == "rework"
      assert healed.state_labels == ["rework"]
      assert healed_state.last_polled_issues[dual.id].state == "rework"

      refute DispatchPolicy.terminal_issue_state?("rework", DispatchPolicy.terminal_state_set())
    end

    test "does not alert for a pair first seen this poll" do
      # The fleet alert is debounced: a pair the heal repairs on the same
      # observation must not alarm. A pair with no prior observation (first seen
      # this poll) sits below the debounce — it is tracked so a pair that
      # persists past one cycle still alerts, but the single fleet line must not
      # fire yet (#2366).
      dual = %{issue("dual-fresh", nil) | state_labels: ["ci-wait", "rework"]}

      {healed_state, _healed} =
        IssueSync.reconcile_contradictory_state_labels(
          %State{},
          [dual],
          fn _id, _target -> :ok end
        )

      refute healed_state.contradictory_state_label_alert_active
      assert is_map(healed_state.contradictory_state_label_tickets[dual.id])
      assert healed_state.contradictory_state_label_tickets[dual.id].since_ms <= System.monotonic_time(:millisecond)

      refute Enum.any?(
               AlertFeed.list(ledger_paths: [AlertLedger.path()], needs_attention: true),
               &(&1["topic"] == "system.fleet.contradictory_state_labels")
             )
    end

    test "keeps the agent's fresh handoff over the daemon's own stale in-progress claim (#2805)" do
      # aiur-team/khala #198: the daemon's CI-pass handoff swapped `ci-wait` ->
      # `in-progress` (recorded in its own `running` entry), and seconds later
      # the agent added `agent:human-review` for the finished PR. The static
      # precedence list is provenance-blind and ranks `in-progress` above
      # `human-review`, so the heal deleted the agent's fresh, deliberate
      # handoff and kept the daemon's stale claim — a ticket waiting for a human
      # read as actively in progress, and the turn loop kept re-waking it.
      #
      # The daemon knows which label is its own prior claim, so the *other*
      # label is the one that arrived since and is the real disposition.
      dual = %{issue("khala-198", nil) | state_labels: ["human-review", "in-progress"]}
      parent = self()

      state = %State{running: %{dual.id => %{issue: issue("khala-198", "in-progress")}}}

      {healed_state, healed_issues} =
        IssueSync.reconcile_contradictory_state_labels(
          state,
          [dual],
          fn identifier, target ->
            send(parent, {:heal, identifier, target})
            :ok
          end
        )

      assert_receive {:heal, "its-everdred/aiur#khala-198", "human-review"}, 1000

      assert [healed] = healed_issues
      assert healed.state == "human-review"
      assert healed.state_labels == ["human-review"]
      assert healed_state.last_polled_issues[dual.id].state == "human-review"
    end

    test "treats the previous poll's single label as the stale claim (#2805)" do
      # The same fresh-vs-stale shape with no running entry: the previous poll
      # observed exactly one state label, so that label is the older one and the
      # label that appeared since is the fresh handoff.
      dual = %{issue("polled-198", nil) | state_labels: ["human-review", "in-progress"]}
      parent = self()

      state = %State{
        last_polled_issues: %{
          dual.id => %{issue("polled-198", "in-progress") | state_labels: ["in-progress"]}
        }
      }

      {_healed_state, healed_issues} =
        IssueSync.reconcile_contradictory_state_labels(
          state,
          [dual],
          fn identifier, target ->
            send(parent, {:heal, identifier, target})
            :ok
          end
        )

      assert_receive {:heal, "its-everdred/aiur#polled-198", "human-review"}, 1000
      assert [%{state: "human-review", state_labels: ["human-review"]}] = healed_issues
    end

    test "falls back to static precedence when no label has known provenance (#2805)" do
      # Provenance is evidence, not a shape rule: with no running entry and no
      # prior single-label observation the daemon cannot tell which label is
      # older, so the deterministic precedence order still decides. This keeps
      # every pre-#2805 resolution unchanged.
      dual = %{issue("no-provenance", nil) | state_labels: ["human-review", "in-progress"]}
      parent = self()

      {_healed_state, healed_issues} =
        IssueSync.reconcile_contradictory_state_labels(
          %State{},
          [dual],
          fn identifier, target ->
            send(parent, {:heal, identifier, target})
            :ok
          end
        )

      assert_receive {:heal, "its-everdred/aiur#no-provenance", "in-progress"}, 1000
      assert [%{state: "in-progress"}] = healed_issues
    end

    test "never lets provenance heal a ticket into the terminal done state (#2805)" do
      # #2437 stands: the terminal `done` must never win a contradiction, even
      # when it is the label that arrived since the daemon's own claim — the
      # tracker write would route into the close path and discard outstanding
      # work. Provenance only promotes a non-terminal disposition.
      dual = %{issue("fresh-done", nil) | state_labels: ["done", "in-progress"]}
      parent = self()

      state = %State{running: %{dual.id => %{issue: issue("fresh-done", "in-progress")}}}

      {_healed_state, healed_issues} =
        IssueSync.reconcile_contradictory_state_labels(
          state,
          [dual],
          fn identifier, target ->
            send(parent, {:heal, identifier, target})
            :ok
          end
        )

      assert_receive {:heal, "its-everdred/aiur#fresh-done", "in-progress"}, 1000
      assert [%{state: "in-progress"}] = healed_issues
    end

    test "keeps todo winning over a stale daemon claim (#2805)" do
      # `todo` means "no work exists yet", so it stays the honest fallback
      # regardless of provenance: a ticket that is also `todo` has not been
      # worked, and promoting the daemon-era disposition would assert work that
      # never happened.
      dual = %{issue("fresh-todo", nil) | state_labels: ["in-progress", "todo"]}
      parent = self()

      state = %State{running: %{dual.id => %{issue: issue("fresh-todo", "in-progress")}}}

      {_healed_state, healed_issues} =
        IssueSync.reconcile_contradictory_state_labels(
          state,
          [dual],
          fn identifier, target ->
            send(parent, {:heal, identifier, target})
            :ok
          end
        )

      assert_receive {:heal, "its-everdred/aiur#fresh-todo", "todo"}, 1000
      assert [%{state: "todo"}] = healed_issues
    end
  end
end
