defmodule Aiur.Orchestrator.ReservedSlotsTest do
  # The Executor held one slot for `slot:voice-review` tickets by hand each
  # hour: without a reserve, every free slot went to whichever ticket ranked
  # first, and a voice review waited behind unrelated work.
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, ReservedSlots, State}

  @label "slot:voice-review"

  setup do
    path = Workflow.workflow_file_path()
    original = File.read!(path)
    on_exit(fn -> File.write!(path, original) end)
    :ok
  end

  describe "dispatch with agent.reserved_slots" do
    test "the last free slot goes to the labelled ticket, not the other ticket" do
      configure(%{@label => 1})
      other = issue("1")
      voice = issue("2", [@label])
      state = state(4, [busy("10"), busy("11"), busy("12")], [other, voice])

      assert DispatchPolicy.dispatch_decision(other, state) == {:skip, :reserved_slot}
      assert DispatchPolicy.dispatch_decision(voice, state) == :dispatch
      assert ReservedSlots.waiting(other, state) == "reserved_slot: 1 held for #{@label}"
    end

    test "without the reserve the same free slot goes to the other ticket" do
      configure(%{})
      other = issue("1")
      state = state(4, [busy("10"), busy("11"), busy("12")], [other, issue("2", [@label])])

      assert DispatchPolicy.dispatch_decision(other, state) == :dispatch
    end

    test "a slot already held by a labelled agent releases the reserve" do
      configure(%{@label => 1})
      other = issue("1")
      state = state(4, [busy("10"), busy("11"), busy("20", [@label])], [other, issue("2", [@label])])

      assert DispatchPolicy.dispatch_decision(other, state) == :dispatch
    end

    test "no reserve is held while no labelled ticket is dispatchable" do
      configure(%{@label => 1})
      other = issue("1")
      paused_voice = %{issue("2", [@label]) | paused: true}
      state = state(4, [busy("10"), busy("11"), busy("12")], [other, paused_voice])

      assert DispatchPolicy.dispatch_decision(other, state) == :dispatch
      assert ReservedSlots.waiting(other, state) == nil
    end

    test "the reserve holds at most one slot per waiting labelled ticket" do
      configure(%{@label => 2})
      other = issue("1")
      state = state(5, [busy("10"), busy("11")], [other, issue("2", [@label])])

      # Three free slots, one labelled ticket waiting: one slot is held, two are free.
      assert ReservedSlots.held_for_others(other, state) == 1
      assert DispatchPolicy.dispatch_decision(other, state) == :dispatch
    end

    test "a labelled ticket backing off before a retry keeps its slot held" do
      configure(%{@label => 1})
      other = issue("1")
      voice = issue("2", [@label])
      state = state(4, [busy("10"), busy("11"), busy("12")], [other, voice])
      state = %{state | claimed: MapSet.put(state.claimed, "2"), retry_attempts: %{"2" => %{attempt: 1}}}

      assert DispatchPolicy.dispatch_decision(other, state) == {:skip, :reserved_slot}
    end

    test "labels match case-insensitively" do
      configure(%{"Slot:Voice-Review" => 1})
      other = issue("1")
      state = state(4, [busy("10"), busy("11"), busy("12")], [other, issue("2", ["SLOT:voice-review"])])

      assert DispatchPolicy.dispatch_decision(other, state) == {:skip, :reserved_slot}
    end

    test "the held-back ticket records reserved_slot as its decline" do
      configure(%{@label => 1})
      other = issue("1")
      voice = issue("2", [@label])
      state = state(4, [busy("10"), busy("11"), busy("12")], [other, voice])

      state = Dispatcher.Candidates.maybe_emit_dispatch_decline(state, other, :reserved_slot)

      assert state.dispatch_declines["1"] == :reserved_slot
    end
  end

  describe "config" do
    test "rejects a count that is not a positive integer" do
      error = assert_raise MatchError, fn -> configure_raw(%{@label => 0}) end
      assert error.term == {:error, {:invalid_workflow_config, "agent.reserved_slots counts must be positive integers"}}
    end

    test "normalizes labels to lower case" do
      configure(%{" Slot:Voice-Review " => 1})
      assert Aiur.Config.settings!().agent.reserved_slots == %{@label => 1}
    end
  end

  defp configure(slots) do
    configure_raw(slots)
    assert {:ok, _} = Aiur.Config.settings()
  end

  defp configure_raw(slots), do: write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 10, reserved_slots: slots)

  defp state(limit, running, polled) do
    %State{
      max_concurrent_agents: limit,
      running: Map.new(running, &{&1.issue.id, &1}),
      last_polled_issues: Map.new(polled, &{&1.id, &1})
    }
  end

  defp busy(id, labels \\ []), do: %{control: %{status: :working}, worker_host: nil, issue: issue(id, labels)}

  defp issue(id, labels \\ []) do
    %Issue{id: id, identifier: "repo##{id}", title: "ticket #{id}", state: "todo", labels: labels, blocked_by: []}
  end
end
