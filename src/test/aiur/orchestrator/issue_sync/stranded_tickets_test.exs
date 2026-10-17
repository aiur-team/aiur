defmodule Aiur.Orchestrator.IssueSync.StrandedTicketsTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State

  describe "sync_stranded_ticket_reconciliation (#2361)" do
    test "strand sweep treats a queued marker-only ticket as legitimately unowned" do
      topic = "ticket.its-everdred/aiur#queued.agent.attention.stranded-requeued"
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe(topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      queued = %{issue("queued", nil) | state_labels: [], queued: true, labels: ["agent:queued"]}
      state = %State{released_claims: %{queued.id => %{cause: :tracker_retry_exhausted}}}

      assert ^state =
               IssueSync.sync_stranded_ticket_reconciliation(
                 state,
                 [queued],
                 fn _id, _target -> flunk("must not re-queue a queued marker-only ticket") end
               )

      refute_receive {:event, %{topic: ^topic}}, 50
    end

    test "re-queues a released-claim ticket with no recovery and alerts" do
      topic = "ticket.its-everdred/aiur#released.agent.attention.stranded-requeued"
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe(topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      stranded = issue("released", "rework")
      parent = self()

      next_state =
        IssueSync.sync_stranded_ticket_reconciliation(
          %State{released_claims: %{"released" => %{cause: :tracker_retry_exhausted}}},
          [stranded],
          fn identifier, target ->
            send(parent, {:requeue, identifier, target})
            :ok
          end
        )

      # A valid `agent:rework` label with a released claim and no recovery is
      # invisible to label checks but has no owner and nothing scheduled to give
      # it one; it must be re-queued to a dispatchable state and surfaced.
      assert_receive {:requeue, "its-everdred/aiur#released", "todo"}, 1000
      assert next_state.released_claims == %{}

      assert_receive {:event, %{topic: ^topic} = alert}, 1000
      assert alert["needs_attention"] == true
      assert alert["reason"] =~ "restored todo"
    end

    test "leaves a released-claim ticket with a scheduled transient resume alone" do
      recovered = issue("recovered", "rework")

      next_state =
        IssueSync.sync_stranded_ticket_reconciliation(
          %State{
            released_claims: %{"recovered" => %{cause: :tracker_retry_exhausted}},
            auto_resume: %{"recovered" => %{attempt: 1, cause: :transient_tracker}}
          },
          [recovered],
          fn _id, _target -> flunk("must not re-queue a ticket with recovery scheduled") end
        )

      assert next_state.released_claims != %{}
    end

    test "leaves a running ticket alone" do
      running = issue("running", "rework")

      next_state =
        IssueSync.sync_stranded_ticket_reconciliation(
          %State{running: %{"running" => %{pid: self(), issue: running}}},
          [running],
          fn _id, _target -> flunk("must not re-queue a ticket with a live owner") end
        )

      assert next_state.released_claims == %{}
    end

    test "leaves a todo ticket waiting for capacity alone" do
      queued = issue("queued", "todo")

      next_state =
        IssueSync.sync_stranded_ticket_reconciliation(
          %State{},
          [queued],
          fn _id, _target -> flunk("must not re-queue a todo ticket queued for dispatch") end
        )

      assert next_state.released_claims == %{}
    end

    test "leaves a ci-wait ticket with no owner alone" do
      waiting = issue("waiting", "ci-wait")

      next_state =
        IssueSync.sync_stranded_ticket_reconciliation(
          %State{},
          [waiting],
          fn _id, _target -> flunk("must not re-queue a ticket waiting on external CI") end
        )

      assert next_state.released_claims == %{}
    end

    test "restores an approved queued stranded PR to ci-wait without requeueing work" do
      waiting = issue("approved-queued", "rework")

      state = %State{
        released_claims: %{waiting.id => %{cause: :tracker_retry_exhausted}},
        ci_lifecycle: %{poll_cache: %{waiting.identifier => %{review_decision: "APPROVED", merge_queue_entry: %{id: "queue"}}}}
      }

      parent = self()

      next_state =
        IssueSync.sync_stranded_ticket_reconciliation(state, [waiting], fn identifier, target ->
          send(parent, {:restored, identifier, target})
          :ok
        end)

      assert_receive {:restored, "its-everdred/aiur#approved-queued", "ci-wait"}, 1000
      assert next_state.released_claims == %{}
    end

    test "closed and done tickets are excluded from stranded repair" do
      for terminal_state <- ["closed", "done"] do
        closed = issue("closed-#{terminal_state}", terminal_state)
        state = %State{released_claims: %{closed.id => %{cause: :tracker_retry_exhausted}}}

        assert ^state =
                 IssueSync.sync_stranded_ticket_reconciliation(state, [closed], fn _identifier, _target ->
                   flunk("a terminal ticket must not be requeued")
                 end)
      end
    end

    test "re-queues a zero-label non-dispatchable ticket to its last known state and alerts" do
      topic = "ticket.its-everdred/aiur#nolabel.agent.attention.stranded-requeued"
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe(topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      # The previous poll saw this ticket under `rework`; the label has since
      # vanished (a broken swap) while the running entry did not survive. The
      # prior polled state is the evidence that re-queuing is a repair rather
      # than a guess at work that never existed (#2420).
      stranded = issue("nolabel", nil)
      parent = self()

      next_state =
        IssueSync.sync_stranded_ticket_reconciliation(
          %State{last_polled_issues: %{stranded.id => issue("nolabel", "rework")}},
          [stranded],
          fn identifier, target ->
            send(parent, {:requeue, identifier, target})
            :ok
          end
        )

      assert_receive {:requeue, "its-everdred/aiur#nolabel", "rework"}, 1000
      assert_receive {:event, %{topic: ^topic} = alert}, 1000
      assert alert["needs_attention"] == true
      assert next_state.released_claims == %{}
    end

    test "leaves a zero-label ticket with no workflow evidence alone" do
      # A ticket that has never entered the agent workflow (no running entry,
      # no released claim, no prior polled state) is untriaged parking, not a
      # strand; the sweep must not re-queue it (#2420).
      untriaged = issue("untriaged", nil)

      next_state =
        IssueSync.sync_stranded_ticket_reconciliation(
          %State{},
          [untriaged],
          fn _id, _target -> flunk("must not re-queue a ticket with no workflow evidence") end
        )

      assert next_state.released_claims == %{}
    end

    test "leaves a deliberately parked zero-label ticket alone" do
      parked = %{issue("parked", nil) | labels: ["human:todo"]}

      next_state =
        IssueSync.sync_stranded_ticket_reconciliation(
          %State{},
          [parked],
          fn _id, _target -> flunk("must not re-queue a deliberately parked ticket") end
        )

      assert next_state.released_claims == %{}
    end
  end
end
