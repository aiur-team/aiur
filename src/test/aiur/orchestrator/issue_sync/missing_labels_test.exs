defmodule Aiur.Orchestrator.IssueSync.MissingLabelsTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.AlertFeed
  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State

  describe "reconcile_contradictory_state_labels (#2075)" do
    test "repairs an issue with no state label and passes through single-labelled issues" do
      single = %{issue("single", "rework") | state_labels: ["rework"]}

      # The zero-label ticket's previous polled copy carried `rework`, which is
      # the positive evidence that it was in the agent workflow and not
      # deliberate parking: a remove-then-add swap dropped the label, so the
      # heal restores the last known state instead of guessing.
      none = %{issue("none", nil) | state_labels: []}
      parent = self()

      {healed_state, healed_issues} =
        IssueSync.reconcile_contradictory_state_labels(
          %State{last_polled_issues: %{none.id => issue("none", "rework")}},
          [single, none],
          fn identifier, target ->
            send(parent, {:heal, identifier, target})
            :ok
          end
        )

      # A zero-label ticket with prior workflow evidence is invisible to
      # dispatch and nothing else repairs it, so it is restored to its last
      # known state and written through the tracker (#2420). A single-labelled
      # ticket passes through untouched.
      assert_receive {:heal, "its-everdred/aiur#none", "rework"}, 1000
      refute_receive {:heal, "its-everdred/aiur#single", _}, 0

      assert Enum.map(healed_issues, & &1.id) == ["single", "none"]
      assert Enum.find(healed_issues, &(&1.id == "none")).state == "rework"
      assert Enum.find(healed_issues, &(&1.id == "none")).state_labels == ["rework"]
      assert healed_state.last_polled_issues[none.id].state == "rework"
      assert healed_state.last_polled_issues[none.id].state_labels == ["rework"]
    end

    test "leaves a zero-label ticket with no workflow evidence alone and alerts without writing" do
      topic = "ticket.its-everdred/aiur#untriaged.agent.attention.state-label-missing-no-evidence"
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe(topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      # A fresh issue with no labels has no running entry and no prior polled
      # state: stamping `agent:todo` on it would guess at work that never
      # existed. It must be left untouched and surfaced with an alert instead
      # of silently re-dispatched (#2420).
      untriaged = %{issue("untriaged", nil) | state_labels: []}

      {healed_state, healed_issues} =
        IssueSync.reconcile_contradictory_state_labels(
          %State{},
          [untriaged],
          fn _id, _target -> flunk("must not write a state label without workflow evidence") end
        )

      assert [left_alone] = healed_issues
      assert left_alone.id == "untriaged"
      assert left_alone.state_labels == []
      assert is_nil(left_alone.state)
      assert healed_state.last_polled_issues == %{}

      assert_receive {:event, %{topic: ^topic} = alert}, 1000
      assert alert["needs_attention"] == true
      assert alert["reason"] =~ "left as-is"
    end

    test "the next label poll resolves a persisted missing-label alert after restart" do
      Publisher.set_tracked_fn(fn _ -> true end)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      for target <- ~w(in-progress rework ci-wait human-review error) do
        recovered = %{issue("recovered-#{target}", target) | state_labels: [target]}
        topic = "ticket.#{recovered.identifier}.agent.attention.state-label-missing-no-evidence"
        resolved_topic = "#{topic}.resolved"
        :ok = Exchange.subscribe(resolved_topic)
        write_central_attention!(topic)
        assert AlertFeed.active_ticket_attention?(topic)

        update = fn _, _ -> flunk("this observation needs no label write") end
        missing = %{recovered | state: nil, state_labels: []}
        {state, [^missing]} = IssueSync.reconcile_contradictory_state_labels(%State{}, [missing], update)
        assert AlertFeed.active_ticket_attention?(topic)
        refute_received {:event, %{topic: ^resolved_topic}}

        {state, [observed]} = IssueSync.reconcile_contradictory_state_labels(state, [recovered], update)
        assert observed.state == target
        assert_received {:event, %{topic: ^resolved_topic}}
        refute AlertFeed.active_ticket_attention?(topic)

        IssueSync.reconcile_contradictory_state_labels(state, [recovered], update)
        mailbox_barrier()
        refute_received {:event, %{topic: ^resolved_topic}}
      end
    end

    test "leaves a deliberately parked zero-label ticket alone" do
      # `needs-triage`, `human:todo`, and `Epic:` containers carry no `agent:*`
      # state label on purpose; dispatching them would reverse deliberate
      # parking, so the heal must not touch them even though they are zero-label
      # (#2420).
      parked = %{issue("parked", nil) | state_labels: [], labels: ["needs-triage"]}
      human_todo = %{issue("human-todo", nil) | state_labels: [], labels: ["human:todo"]}
      epic = %{issue("epic", nil) | state_labels: [], labels: ["epic:fleet"]}

      {healed_state, healed_issues} =
        IssueSync.reconcile_contradictory_state_labels(
          %State{},
          [parked, human_todo, epic],
          fn _id, _target -> flunk("must not rewrite a deliberately parked ticket") end
        )

      assert Enum.map(healed_issues, & &1.id) == ["parked", "human-todo", "epic"]
      assert Enum.all?(healed_issues, &(&1.state_labels == []))
      assert healed_state.last_polled_issues == %{}
    end

    test "leaves an agent:paused zero-label ticket alone and raises no attention alert" do
      # `agent:paused` is a marker suffix, not a state suffix, so an
      # operator-gated ticket carrying only `agent:paused` normalizes to zero
      # state labels. It is deliberate parking, so the heal must neither rewrite
      # it nor raise `state-label-missing-no-evidence` (#2610).
      topic = "ticket.its-everdred/aiur#held.agent.attention.state-label-missing-no-evidence"
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe(topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      held = %{issue("held", nil) | state_labels: [], paused: true, labels: ["agent:paused", "complexity:2"]}

      {healed_state, healed_issues} =
        IssueSync.reconcile_contradictory_state_labels(
          %State{},
          [held],
          fn _id, _target -> flunk("must not rewrite a paused ticket") end
        )

      assert [left_alone] = healed_issues
      assert left_alone.id == "held"
      assert left_alone.state_labels == []
      assert is_nil(left_alone.state)
      assert healed_state.last_polled_issues == %{}

      refute_receive {:event, %{topic: ^topic}}, 50
    end

    test "leaves a queued marker-only ticket alone although its last poll was todo" do
      topic = "ticket.its-everdred/aiur#queued.agent.attention.state-label-missing"
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe(topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      queued = %{issue("queued", nil) | state_labels: [], queued: true, labels: ["agent:queued"]}
      prior_state = %State{last_polled_issues: %{queued.id => issue("queued", "todo")}}

      assert {^prior_state, [^queued]} =
               IssueSync.reconcile_contradictory_state_labels(
                 prior_state,
                 [queued],
                 fn _id, _target -> flunk("must not restore todo on a queued ticket") end
               )

      refute_receive {:event, %{topic: ^topic}}, 50
    end

    test "raises no state-label-missing-no-evidence for a queued ticket" do
      topic = "ticket.its-everdred/aiur#queued.agent.attention.state-label-missing-no-evidence"
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe(topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      queued = %{issue("queued", nil) | state_labels: [], queued: true, labels: ["agent:queued"]}
      state = %State{}

      assert {^state, [^queued]} =
               IssueSync.reconcile_contradictory_state_labels(
                 state,
                 [queued],
                 fn _id, _target -> flunk("must not rewrite a queued ticket") end
               )

      refute_receive {:event, %{topic: ^topic}}, 50
    end

    test "leaves an agent:paused zero-label ticket alone even with prior workflow evidence" do
      # A ticket the operator paused after it had been running still carries the
      # parking marker, so the last-known-state heal must not fire and re-arm
      # dispatch behind the operator's back (#2610).
      held = %{issue("held", nil) | state_labels: [], paused: true, labels: ["agent:paused"]}

      {healed_state, healed_issues} =
        IssueSync.reconcile_contradictory_state_labels(
          %State{last_polled_issues: %{held.id => issue("held", "in-progress")}},
          [held],
          fn _id, _target -> flunk("must not rewrite a paused ticket") end
        )

      assert [left_alone] = healed_issues
      assert left_alone.state_labels == []
      assert is_nil(left_alone.state)
      assert healed_state.last_polled_issues[held.id].state == "in-progress"
      assert healed_state.last_polled_issues[held.id].state_labels == nil
    end

    test "restores a zero-label ticket to its last known running state and alerts" do
      topic = "ticket.its-everdred/aiur#sweep.agent.attention.state-label-missing"
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe(topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      stranded = %{issue("sweep", nil) | state_labels: []}

      running_entry = %{
        pid: self(),
        identifier: "its-everdred/aiur#sweep",
        issue: issue("sweep", "in-progress")
      }

      {healed_state, healed_issues} =
        IssueSync.reconcile_contradictory_state_labels(
          %State{running: %{"sweep" => running_entry}},
          [stranded],
          fn _id, _target -> :ok end
        )

      assert [healed] = healed_issues
      assert healed.state == "in-progress"
      assert healed.state_labels == ["in-progress"]
      assert healed_state.last_polled_issues["sweep"].state_labels == ["in-progress"]

      assert_receive {:event, %{topic: ^topic} = alert}, 1000
      assert alert["needs_attention"] == true
      assert alert["reason"] =~ "restored in-progress"
    end

    test "keeps a zero-label issue dispatchable even when the heal write fails" do
      # Evidence of prior workflow membership (the previous poll saw `rework`)
      # is what makes the heal attempt; the write failing must not strand the
      # ticket this cycle.
      none = %{issue("none", nil) | state_labels: []}

      {healed_state, healed_issues} =
        IssueSync.reconcile_contradictory_state_labels(
          %State{last_polled_issues: %{none.id => issue("none", "rework")}},
          [none],
          fn _id, _target -> {:error, :github_down} end
        )

      assert [healed] = healed_issues
      assert healed.state == "rework"
      assert healed.state_labels == ["rework"]

      # A failed heal write must not strand the ticket this cycle: the healed
      # issue is returned dispatchable, and the original evidence entry (not a
      # healed copy) is what last_polled_issues still holds so the next poll
      # retries the heal.
      assert healed_state.last_polled_issues == %{none.id => issue("none", "rework")}
    end
  end
end
