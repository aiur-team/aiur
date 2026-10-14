defmodule Aiur.Orchestrator.AutoResumeIntegrationTest do
  use Aiur.TestSupport

  import Aiur.Orchestrator.AutoResumeTestSupport

  alias Aiur.DispatchBudgetStore
  alias Aiur.Orchestrator.{AutoResume, Dispatcher, RetryEngine, State, TrackerTasks}

  @issue_id "issue-transient"
  @enabled enabled_config()

  setup :auto_resume_setup

  describe "maybe_resume/3" do
    test "slow state restore runs outside owner and respects a newer pause" do
      name = {__MODULE__, make_ref()}
      :yes = :global.register_name(name, self())
      on_exit(fn -> :global.unregister_name(name) end)
      state = %{due_state(issue()) | snapshot_key: {:global, name}}
      parent = self()

      next =
        AutoResume.maybe_resume(state, System.monotonic_time(:millisecond),
          admission_fun: admit(),
          update_state_fun: fn _identifier, "todo" ->
            send(parent, {:restore_started, self()})

            receive do
              :finish_restore -> :ok
            end
          end,
          dispatch_fun: fn _current, _issue -> flunk("newer pause must suppress restore dispatch") end
        )

      receive_barrier({:restore_started, worker})
      assert worker != self()
      ref = next.tracker_tasks |> Map.keys() |> hd()
      paused = issue(%{paused: true, labels: ["agent:paused"]})
      current = %{next | last_polled_issues: %{@issue_id => paused}, claimed: MapSet.new(["other-ticket"])}
      send(worker, :finish_restore)
      receive_barrier({^ref, result})
      assert {:handled, applied} = TrackerTasks.result(current, ref, result)
      assert applied.last_polled_issues[@issue_id] == paused
      assert applied.claimed == MapSet.new(["other-ticket"])
      assert applied.auto_resume[@issue_id].attempt == 1
    end

    test "pending dispatch validation does not spend an auto-resume attempt" do
      parent = self()
      state = due_state(issue(%{state: "rework"}))
      entry = state.auto_resume[@issue_id]

      next =
        AutoResume.maybe_resume(state, System.monotonic_time(:millisecond),
          admission_fun: admit(),
          dispatch_fun: fn current, ticket ->
            TrackerTasks.start(
              current,
              {:dispatch, ticket.id},
              fn ->
                send(parent, {:dispatch_validation_started, self()})

                receive do
                  :finish_validation -> :ok
                end
              end,
              fn current, :ok -> claim_fun(current, ticket) end
            )
          end
        )

      receive_barrier({:dispatch_validation_started, worker})
      assert next.auto_resume[@issue_id] == entry
      again = AutoResume.maybe_resume(next, System.monotonic_time(:millisecond), dispatch_fun: fn _, _ -> flunk("validation already pending") end)
      assert again.auto_resume[@issue_id] == entry
      ref = next.tracker_tasks |> Map.keys() |> hd()
      send(worker, :finish_validation)
      receive_barrier({^ref, result})
      assert {:handled, applied} = TrackerTasks.result(again, ref, result)
      assert MapSet.member?(applied.claimed, @issue_id)
    end

    @tag config: @enabled
    test "re-dispatches a due agent:error ticket after restoring it to todo, never rework" do
      # #2075 criterion 3: restoring an `agent:error` ticket to a dispatchable
      # state must write `todo`, not `rework` — nothing here rejected the work
      # (a transient infra fault only needs "make this dispatchable again"),
      # and a `rework` verdict on a ticket with no open PR would strand it in a
      # state nothing selects. The precondition this writer requires is
      # "transient fault, no review verdict", which `todo` names and `rework`
      # would lie about.
      state = due_state(issue())
      now_ms = System.monotonic_time(:millisecond)
      parent = self()

      state =
        AutoResume.maybe_resume(state, now_ms,
          admission_fun: admit(),
          update_state_fun: fn identifier, target ->
            send(parent, {:restored, identifier, target})
            :ok
          end,
          dispatch_fun: &claim_fun/2
        )

      assert_receive {:restored, "repo#transient", "todo"}, 1000
      assert MapSet.member?(state.claimed, @issue_id)
      refute Map.has_key?(state.auto_resume, @issue_id)
    end

    @tag config: @enabled
    test "dispatches a due rework ticket directly without a state flip" do
      state = due_state(issue(%{state: "rework"}))
      now_ms = System.monotonic_time(:millisecond)

      state =
        AutoResume.maybe_resume(state, now_ms,
          admission_fun: admit(),
          update_state_fun: fn _id, _target -> flunk("rework ticket must not be relabelled") end,
          dispatch_fun: &claim_fun/2
        )

      assert MapSet.member?(state.claimed, @issue_id)
    end

    @tag config: @enabled
    test "an operator-paused ticket never auto-resumes" do
      paused = issue(%{paused: true, labels: ["agent:paused"]})
      state = due_state(paused)
      now_ms = System.monotonic_time(:millisecond)

      state =
        AutoResume.maybe_resume(state, now_ms, dispatch_fun: fn _s, _i -> flunk("paused ticket must not dispatch") end)

      refute MapSet.member?(state.claimed, @issue_id)
      refute Map.has_key?(state.auto_resume, @issue_id)
    end

    @tag config: @enabled
    test "a lifetime-latched ticket never auto-resumes" do
      :ok = DispatchBudgetStore.put_lifetime(@issue_id, 10)
      state = due_state(issue())
      now_ms = System.monotonic_time(:millisecond)

      state =
        AutoResume.maybe_resume(state, now_ms, dispatch_fun: fn _s, _i -> flunk("latched ticket must not dispatch") end)

      refute MapSet.member?(state.claimed, @issue_id)
      refute Map.has_key?(state.auto_resume, @issue_id)
    end

    @tag config: @enabled
    test "auto-resume recovers a ticket that previously latched once the latch is reset" do
      # #1453 amendment acceptance: the auto-resume retry path must check the
      # lifetime latch but not be swallowed by it. A ticket that tripped the
      # latch, had it reset via the supported exit, and then failed on a fresh
      # transient cause still auto-resumes — the retry path is not wedged by
      # the old latch.
      :ok = DispatchBudgetStore.put_lifetime(@issue_id, 10)
      state = due_state(issue())
      now_ms = System.monotonic_time(:millisecond)

      # Latched: refused and the pending entry is dropped.
      state =
        AutoResume.maybe_resume(state, now_ms, dispatch_fun: fn _s, _i -> flunk("latched ticket must not dispatch") end)

      refute MapSet.member?(state.claimed, @issue_id)
      refute Map.has_key?(state.auto_resume, @issue_id)

      # Operator clears the latch through the supported exit (both copies).
      {state, :ok} = Dispatcher.reset_lifetime_budget(state, @issue_id)
      assert :none = Dispatcher.dispatch_latch_status(state, @issue_id)

      # A fresh transient failure schedules a new auto-resume, which now
      # dispatches normally — the retry path is not swallowed by the budget.
      due_entry = %{
        attempt: 1,
        cause: :transient_tracker,
        scheduled_at_ms: System.monotonic_time(:millisecond) - AutoResume.backoff_ms(1) - 1_000
      }

      state = %{state | auto_resume: Map.put(state.auto_resume, @issue_id, due_entry)}

      state =
        AutoResume.maybe_resume(state, System.monotonic_time(:millisecond),
          admission_fun: admit(),
          update_state_fun: fn _id, _target -> :ok end,
          dispatch_fun: &claim_fun/2
        )

      assert MapSet.member?(state.claimed, @issue_id)
      refute Map.has_key?(state.auto_resume, @issue_id)
    end

    @tag config: @enabled
    test "a terminal ticket never auto-resumes and drops the entry" do
      state = due_state(issue(%{state: "done"}))
      now_ms = System.monotonic_time(:millisecond)

      state =
        AutoResume.maybe_resume(state, now_ms, dispatch_fun: fn _s, _i -> flunk("terminal ticket must not dispatch") end)

      refute Map.has_key?(state.auto_resume, @issue_id)
    end

    @tag config: @enabled
    test "a deferred dispatch backs off and retries on a later poll" do
      state = due_state(issue())
      now_ms = System.monotonic_time(:millisecond)

      state =
        AutoResume.maybe_resume(state, now_ms,
          admission_fun: admit(),
          update_state_fun: fn _id, _target -> :ok end,
          dispatch_fun: fn state, _issue -> state end
        )

      # Not claimed; the entry was rescheduled with a bumped attempt.
      refute MapSet.member?(state.claimed, @issue_id)
      assert %{attempt: 2, cause: :transient_tracker} = state.auto_resume[@issue_id]
    end

    @tag config: @enabled
    test "an admission hold defers without spending a bounded attempt" do
      # #1453 review P1/P2a: when the fleet is globally paused, at capacity, or
      # under a prewarm/load hold, auto-resume must not spawn AND must not burn
      # one of its 3 bounded attempts on a non-causal deferral — the ticket
      # keeps its budget and re-checks on the next poll once the hold lifts.
      state = due_state(issue())
      now_ms = System.monotonic_time(:millisecond)

      state =
        AutoResume.maybe_resume(state, now_ms,
          admission_fun: fn _state -> {:hold, :global_pause} end,
          dispatch_fun: fn _s, _i -> flunk("admission hold must not dispatch") end
        )

      refute MapSet.member?(state.claimed, @issue_id)
      # Same attempt retained; the entry stays due for the next poll.
      assert %{attempt: 1, cause: :transient_tracker} = state.auto_resume[@issue_id]

      state =
        AutoResume.maybe_resume(state, now_ms,
          admission_fun: fn _state -> {:hold, :max_concurrent_agents} end,
          dispatch_fun: fn _s, _i -> flunk("admission hold must not dispatch") end
        )

      refute MapSet.member?(state.claimed, @issue_id)
      assert %{attempt: 1} = state.auto_resume[@issue_id]

      # A prewarm / host-pressure hold defers the same way (no attempt burned).
      state =
        AutoResume.maybe_resume(state, now_ms,
          admission_fun: fn _state -> {:hold, :prewarm} end,
          dispatch_fun: fn _s, _i -> flunk("admission hold must not dispatch") end
        )

      refute MapSet.member?(state.claimed, @issue_id)
      assert %{attempt: 1} = state.auto_resume[@issue_id]

      # Once the hold lifts, the retained entry dispatches on a later poll.
      state =
        AutoResume.maybe_resume(state, now_ms,
          admission_fun: admit(),
          update_state_fun: fn _identifier, "todo" -> :ok end,
          dispatch_fun: &claim_fun/2
        )

      assert MapSet.member?(state.claimed, @issue_id)
      refute Map.has_key?(state.auto_resume, @issue_id)
    end

    @tag config: @enabled
    test "a ticket with no tracked issue drops the entry" do
      now_ms = System.monotonic_time(:millisecond)
      scheduled_at = now_ms - AutoResume.backoff_ms(1) - 1_000

      state = %State{
        auto_resume: %{@issue_id => %{attempt: 1, cause: :transient_tracker, scheduled_at_ms: scheduled_at}}
      }

      state = AutoResume.maybe_resume(state, now_ms)
      refute Map.has_key?(state.auto_resume, @issue_id)
    end
  end

  describe "RetryEngine integration" do
    @tag config: @enabled
    test "maybe_schedule_transient_auto_resume schedules a transient cause" do
      state =
        RetryEngine.maybe_schedule_transient_auto_resume(%State{}, @issue_id, {:github, :rate_limited, %{status: 403}})

      assert %{attempt: 1, cause: :rate_limit} = state.auto_resume[@issue_id]
    end

    @tag config: @enabled
    test "maybe_schedule_transient_auto_resume ignores terminal causes" do
      state =
        RetryEngine.maybe_schedule_transient_auto_resume(%State{}, @issue_id, {:github, :auth, %{status: 401}})

      refute Map.has_key?(state.auto_resume, @issue_id)
    end

    # A DNS transport failure reaching the retry-exhaustion path schedules the
    # same transient auto-resume as a classified tracker fault (#2429 / #2427).
    @tag config: @enabled
    test "maybe_schedule_transient_auto_resume schedules a DNS failure" do
      state =
        RetryEngine.maybe_schedule_transient_auto_resume(
          %State{},
          @issue_id,
          {:error, %Req.TransportError{reason: :nxdomain}}
        )

      assert %{attempt: 1, cause: :transient_tracker} = state.auto_resume[@issue_id]
    end
  end
end
