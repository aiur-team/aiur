defmodule Aiur.AgentRunner.TurnLoopTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.TurnLoop

  # A briefly overloaded orchestrator queue GenServer answers the restore RPC
  # with `{:error, :unavailable}` / `:timeout` for a few calls before it
  # recovers. `calls` proves how many restore attempts the boundary made.
  defmodule FlakyRestoreOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok,
       %{
         unavailable_left: Keyword.fetch!(opts, :unavailable),
         reason: Keyword.get(opts, :reason, :unavailable),
         calls: 0
       }}
    end

    @impl true
    def handle_call({:restore_delivered_queue_items, _identifier}, _from, state) do
      state = %{state | calls: state.calls + 1}

      if state.unavailable_left > 0 do
        {:reply, {:error, state.reason}, %{state | unavailable_left: state.unavailable_left - 1}}
      else
        {:reply, :ok, state}
      end
    end

    def handle_call(:calls, _from, state), do: {:reply, state.calls, state}
  end

  # #1238: the one confirmed restore-and-replace boundary shared by the
  # primary-turn (`run_turns`) and queue-drain (`run_recorded_queue_item_turn`)
  # seams. It must confirm the durable restore before reporting a clean
  # replacement exit, and must never silently strand the delivered item.
  describe "confirm_restore_for_replacement/4" do
    setup do
      %{issue: %Aiur.Issue{id: "gid-1238", identifier: "TL-1238"}}
    end

    test "retries a transient unavailable restore, then returns the recoverable error", %{issue: issue} do
      {:ok, orch} = FlakyRestoreOrchestrator.start_link(unavailable: 2)

      assert TurnLoop.confirm_restore_for_replacement(
               orch,
               issue,
               [restore_confirm_backoff_ms: 0],
               {:error, :port_closed}
             ) == {:error, :port_closed}

      # Two unavailable answers were retried through; the third confirmed.
      assert GenServer.call(orch, :calls) == 3
    end

    test "retries a transient timeout restore the same way", %{issue: issue} do
      {:ok, orch} = FlakyRestoreOrchestrator.start_link(unavailable: 1, reason: :timeout)

      assert TurnLoop.confirm_restore_for_replacement(
               orch,
               issue,
               [restore_confirm_backoff_ms: 0],
               {:error, {:turn_interrupt_failed, :port_closed}}
             ) == {:error, {:turn_interrupt_failed, :port_closed}}

      assert GenServer.call(orch, :calls) == 2
    end

    test "refuses to report clean recovery when the restore never confirms", %{issue: issue} do
      {:ok, orch} = FlakyRestoreOrchestrator.start_link(unavailable: 99)

      assert TurnLoop.confirm_restore_for_replacement(
               orch,
               issue,
               [restore_confirm_backoff_ms: 0, restore_confirm_attempts: 3],
               {:error, :port_closed}
             ) == {:error, {:queue_restore_unconfirmed, :unavailable}}

      # Bounded: it stops at the attempt cap instead of spinning forever.
      assert GenServer.call(orch, :calls) == 3
    end

    test "an immediately available restore confirms in a single call", %{issue: issue} do
      {:ok, orch} = FlakyRestoreOrchestrator.start_link(unavailable: 0)

      assert TurnLoop.confirm_restore_delivered(orch, issue, restore_confirm_backoff_ms: 0) == :ok
      assert GenServer.call(orch, :calls) == 1
    end
  end

  describe "turn_done_reason/1" do
    # #1024 / #1041: a turn that ends on an unresolved operator decision (or a
    # dependency blocker / scope question) must NOT recurse into a work turn —
    # `finalize_turn_completion` is only reached on `{:ok, _}`. A `:paused`
    # outcome is `:input_required`, which parks the run in `wait_for_resume`;
    # that is the code-enforced negative half of the planning-to-work contract
    # (no false-positive start of work on an unfinished plan).
    test "maps coding-agent turn results to stream close reasons" do
      assert TurnLoop.turn_done_reason({:ok, %{}}) == :done
      assert TurnLoop.turn_done_reason({:paused, %{}}) == :input_required
      assert TurnLoop.turn_done_reason({:paused, %{reason: :operator_decision}}) == :input_required
      assert TurnLoop.turn_done_reason({:paused, %{reason: :dependency_blocker}}) == :input_required
      assert TurnLoop.turn_done_reason({:error, :boom}) == {:failed, :boom}
      assert TurnLoop.turn_done_reason(:other) == :done
    end
  end

  describe "max_turns_display/1" do
    test "renders nil as infinity and integers as strings" do
      assert TurnLoop.max_turns_display(nil) == "∞"
      assert TurnLoop.max_turns_display(3) == "3"
    end
  end

  describe "return_completed/2" do
    test "returns the final boundary for publication after outer cleanup" do
      issue = %Aiur.Issue{id: "issue-completed"}

      assert {:completed, ^issue} =
               TurnLoop.return_completed(%{codex_update_recipient: self()}, issue)

      refute_receive {:worker_control_state, "issue-completed", :completed}
    end
  end

  describe "continue_with_issue?/2" do
    setup do
      # The default workflow config in the test environment resolves
      # `tracker.active_states` to ["todo", "in-progress", "rework", "merging"].
      # Pick an actual active state so the continue/done decisions are decided
      # by the paused override (or the state transition), not by the test state
      # accidentally being inactive.
      active_states = Aiur.Config.settings!().tracker.active_states

      %{active_state: Enum.at(active_states, 0)}
    end

    test "continues for an active, non-paused issue", %{active_state: active_state} do
      issue = %Aiur.Issue{id: "issue-active", identifier: "MT-ACTIVE", state: active_state}
      refreshed = %{issue | state: active_state}

      assert {:continue, ^refreshed} =
               TurnLoop.continue_with_issue?(issue, fn ["issue-active"] -> {:ok, [refreshed]} end)
    end

    # #1686: a ticket carrying the `agent:paused` override must stop receiving
    # automatic continuation turns even though its underlying state label stays
    # in `tracker.active_states`. `continue_with_issue?/2` must consult
    # `Issue.paused?/1`; recursing on the state label alone fires turn after
    # turn on a paused ticket until `agent.max_turns` is reached.
    test "stops for an active issue carrying the paused override", %{active_state: active_state} do
      issue = %Aiur.Issue{
        id: "issue-paused",
        identifier: "MT-PAUSED",
        state: active_state,
        paused: true
      }

      refreshed = %{issue | state: active_state}

      assert {:done, ^refreshed} =
               TurnLoop.continue_with_issue?(issue, fn ["issue-paused"] -> {:ok, [refreshed]} end)
    end

    test "stops for an inactive issue", %{active_state: _active_state} do
      issue = %Aiur.Issue{id: "issue-done", identifier: "MT-DONE", state: "In Progress"}
      refreshed = %{issue | state: "Done"}

      assert {:done, ^refreshed} =
               TurnLoop.continue_with_issue?(issue, fn ["issue-done"] -> {:ok, [refreshed]} end)
    end

    test "stops when the refresh returns no matching issue" do
      issue = %Aiur.Issue{id: "issue-missing", identifier: "MT-MISSING", state: "todo"}

      assert {:done, ^issue} =
               TurnLoop.continue_with_issue?(issue, fn ["issue-missing"] -> {:ok, []} end)
    end

    test "surfaces a refresh error" do
      issue = %Aiur.Issue{id: "issue-error", identifier: "MT-ERROR", state: "todo"}

      assert {:error, {:issue_state_refresh_failed, :boom}} =
               TurnLoop.continue_with_issue?(issue, fn ["issue-error"] ->
                 {:error, :boom}
               end)
    end
  end

  describe "continue_after_resume/2" do
    test "returns a completed boundary when max turns were already reached" do
      issue = %Aiur.Issue{id: "issue-max", identifier: "MT-MAX", state: "In Progress"}
      refreshed = %{issue | state: "In Progress"}

      context = %{
        issue: issue,
        issue_state_fetcher: fn ["issue-max"] -> {:ok, [refreshed]} end,
        max_turns: 1,
        turn_number: 1
      }

      assert {:completed, ^refreshed} = TurnLoop.continue_after_resume(context, %{})
    end

    test "returns a completed boundary when the refreshed issue is inactive" do
      issue = %Aiur.Issue{id: "issue-done", identifier: "MT-DONE", state: "In Progress"}
      refreshed = %{issue | state: "Done"}

      context = %{
        issue: issue,
        issue_state_fetcher: fn ["issue-done"] -> {:ok, [refreshed]} end,
        max_turns: 3,
        turn_number: 1
      }

      assert {:completed, ^refreshed} = TurnLoop.continue_after_resume(context, %{})
    end

    # #1686: a paused ticket must not recurse into another continuation turn
    # after a resume, even while turns remain and its state label is active.
    test "returns a completed boundary when the refreshed issue is paused" do
      active_state = Enum.at(Aiur.Config.settings!().tracker.active_states, 0)

      issue = %Aiur.Issue{
        id: "issue-paused",
        identifier: "MT-PAUSED",
        state: active_state,
        paused: true
      }

      refreshed = %{issue | state: active_state}

      context = %{
        issue: issue,
        issue_state_fetcher: fn ["issue-paused"] -> {:ok, [refreshed]} end,
        max_turns: 3,
        turn_number: 1
      }

      assert {:completed, ^refreshed} = TurnLoop.continue_after_resume(context, %{})
    end

    test "returns a completed boundary when the refreshed issue has no matching issue" do
      issue = %Aiur.Issue{id: "issue-missing", identifier: "MT-MISSING", state: "In Progress"}

      context = %{
        issue: issue,
        issue_state_fetcher: fn ["issue-missing"] -> {:ok, []} end,
        max_turns: 3,
        turn_number: 1
      }

      assert {:completed, ^issue} = TurnLoop.continue_after_resume(context, %{})
    end
  end
end
