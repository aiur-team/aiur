defmodule Aiur.Orchestrator.AutoResumeTest do
  use Aiur.TestSupport

  alias Aiur.{DispatchBudgetStore, Issue, Workflow}
  alias Aiur.Orchestrator.{AutoResume, Dispatcher, RetryEngine, State}

  @issue_id "issue-transient"
  @enabled """
  tracker:
    kind: memory
    active_states:
      - todo
      - in-progress
      - rework
    terminal_states:
      - done
  agent:
    kind: codex
    max_dispatches_per_ticket: 10
  """

  setup attrs do
    config = Map.get(attrs, :config, @enabled)
    previous_store = Application.get_env(:aiur, :dispatch_budget_store_path)
    previous_state_dir = Application.get_env(:aiur, :decision_state_dir)
    previous_log_file = Application.get_env(:aiur, :log_file)
    dir = Path.join(System.tmp_dir!(), "aiur-auto-resume-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "config.yaml")
    File.write!(path, config)
    Workflow.set_workflow_file_path(path)
    Application.delete_env(:aiur, :dispatch_budget_store_path)
    Application.put_env(:aiur, :decision_state_dir, Path.join(dir, "stable-state"))
    Application.put_env(:aiur, :log_file, Path.join([dir, "session-one", "aiur.log"]))

    on_exit(fn ->
      File.rm_rf!(dir)

      if is_nil(previous_store) do
        Application.delete_env(:aiur, :dispatch_budget_store_path)
      else
        Application.put_env(:aiur, :dispatch_budget_store_path, previous_store)
      end

      if is_nil(previous_state_dir) do
        Application.delete_env(:aiur, :decision_state_dir)
      else
        Application.put_env(:aiur, :decision_state_dir, previous_state_dir)
      end

      if is_nil(previous_log_file) do
        Application.delete_env(:aiur, :log_file)
      else
        Application.put_env(:aiur, :log_file, previous_log_file)
      end
    end)

    :ok
  end

  defp issue(overrides \\ %{}) do
    struct!(
      Issue,
      Map.merge(
        %{id: @issue_id, identifier: "repo#transient", title: "transient", state: "error", labels: []},
        overrides
      )
    )
  end

  defp state_with(%{last_polled_issues: issues, auto_resume: auto_resume}) do
    %State{last_polled_issues: Map.new(issues, &{&1.id, &1}), auto_resume: auto_resume}
  end

  defp due_state(issue, attempt \\ 1) do
    scheduled_at = System.monotonic_time(:millisecond) - AutoResume.backoff_ms(attempt) - 1_000
    state_with(%{last_polled_issues: [issue], auto_resume: %{issue.id => %{attempt: attempt, cause: :transient_tracker, scheduled_at_ms: scheduled_at}}})
  end

  defp claim_fun(state, issue) do
    %{state | claimed: MapSet.put(state.claimed, issue.id)}
  end

  # Tests that exercise the dispatch path inject a permissive admission gate so
  # the result does not depend on the host's live load/FD sample; the real gate
  # (`Dispatcher.auto_resume_admission/1`) is unit-tested separately and the
  # hold-deferral behaviour is covered by the injected-hold tests below.
  defp admit, do: fn _state -> :dispatch end

  describe "classify/1" do
    test "classifies transient tracker failures" do
      assert AutoResume.classify({:github, :rate_limited, %{status: 403}}) == :rate_limit
      assert AutoResume.classify({:github, :timeout, %{reason: :timeout}}) == :transient_tracker
      assert AutoResume.classify({:github, :transport, %{reason: :econnrefused}}) == :transient_tracker
      assert AutoResume.classify({:github, :http, %{status: 500}}) == :transient_tracker
    end

    test "classifies provider timeouts" do
      assert AutoResume.classify(:timeout) == :provider_timeout
      assert AutoResume.classify({:error, :timeout}) == :provider_timeout
      assert AutoResume.classify({:timeout, %{url: "x"}}) == :provider_timeout
    end

    test "returns nil for terminal and operator causes" do
      assert AutoResume.classify({:github, :auth, %{status: 401}}) == nil
      assert AutoResume.classify({:github, :permission, %{status: 403}}) == nil
      assert AutoResume.classify({:github, :http, %{status: 403}}) == nil
      assert AutoResume.classify(:operator_pause) == nil
      assert AutoResume.classify(nil) == nil
    end
  end

  describe "schedule/3" do
    test "records a pending resume and reports the backoff" do
      state = AutoResume.schedule(%State{}, @issue_id, :rate_limit)

      assert %{attempt: 1, cause: :rate_limit} = state.auto_resume[@issue_id]
      assert AutoResume.retry_in_ms(state, @issue_id, System.monotonic_time(:millisecond)) <= 120_000
      assert AutoResume.retry_in_ms(state, @issue_id, System.monotonic_time(:millisecond)) > 0
    end

    test "honors a rate-limit retry-after before attempting re-claim" do
      state = AutoResume.schedule(%State{}, @issue_id, :rate_limit, retry_after: 600)

      assert AutoResume.retry_in_ms(state, @issue_id, System.monotonic_time(:millisecond)) > 590_000
    end

    test "advances through the bounded backoff schedule" do
      state = %State{}
      assert AutoResume.backoff_ms(1) == 120_000
      assert AutoResume.backoff_ms(2) == 300_000
      assert AutoResume.backoff_ms(3) == 900_000

      # A fourth schedule drops the entry (bounded at max_attempts).
      max_attempts = AutoResume.max_attempts()

      state =
        Enum.reduce(1..max_attempts, state, fn _i, acc ->
          AutoResume.schedule(acc, @issue_id, :transient_tracker)
        end)

      assert %{attempt: ^max_attempts} = state.auto_resume[@issue_id]

      state = AutoResume.schedule(state, @issue_id, :transient_tracker)
      refute Map.has_key?(state.auto_resume, @issue_id)
    end

    test "keeps the released-claim record when automatic recovery exhausts" do
      state = %State{released_claims: %{@issue_id => %{cause: :rate_limit, details: %{}, released_at_ms: 1}}}

      state =
        Enum.reduce(1..(AutoResume.max_attempts() + 1), state, fn _i, acc ->
          AutoResume.schedule(acc, @issue_id, :rate_limit)
        end)

      refute Map.has_key?(state.auto_resume, @issue_id)
      assert %{cause: :rate_limit} = state.released_claims[@issue_id]
    end

    test "exhausting the attempt budget emits the operator alert the docstring promises" do
      # #1453 review P2a: `schedule/3` documents "an operator alert is emitted"
      # once the bounded budget is spent, but the original implementation only
      # logged. Exhaustion must surface as a needs-attention alert so a parked
      # ticket is diagnosable rather than silently dropped.
      parent = self()

      state =
        Enum.reduce(1..AutoResume.max_attempts(), %State{}, fn _i, acc ->
          AutoResume.schedule(acc, @issue_id, :rate_limit)
        end)

      state =
        AutoResume.schedule(state, @issue_id, :rate_limit, fn name, opts ->
          send(parent, {:exhaustion_alert, name, opts})
          :ok
        end)

      assert_receive {:exhaustion_alert, "ticket.#{@issue_id}.agent.auto_resume_exhausted", opts}
      assert Keyword.get(opts, :needs_attention) == true
      refute Map.has_key?(state.auto_resume, @issue_id)
    end
  end

  describe "Dispatcher.auto_resume_admission/1" do
    @tag config: @enabled
    test "holds during a global pause" do
      assert {:hold, :global_pause} = Dispatcher.auto_resume_admission(%State{globally_paused: true})
    end

    @tag config: @enabled
    test "holds at concurrent-agent capacity" do
      state = %State{
        max_concurrent_agents: 1,
        running: %{"other" => %{control: %{status: :working}}}
      }

      assert {:hold, :max_concurrent_agents} = Dispatcher.auto_resume_admission(state)
    end

    @tag config: @enabled
    test "admits a free-capacity, unpaused fleet without host-pressure holds" do
      # Pin the host probes so the result does not depend on the CI host's live
      # load/FD sample; with free capacity the mirror of the normal admission
      # path admits, so the auto-resume can dispatch.
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)

      Application.put_env(:aiur, :file_descriptor_sample_override, fn ->
        %{pid: "1", used: 10, limit: 100_000, available: 99_990, headroom_ratio: 0.9999}
      end)

      on_exit(fn ->
        Application.delete_env(:aiur, :loadavg_source_override)
        Application.delete_env(:aiur, :file_descriptor_sample_override)
      end)

      assert :dispatch = Dispatcher.auto_resume_admission(%State{})
    end
  end

  describe "maybe_resume/3" do
    @tag config: @enabled
    test "re-dispatches a due agent:error ticket after restoring it to rework" do
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

      assert_receive {:restored, "repo#transient", "rework"}
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
  end
end
