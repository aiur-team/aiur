defmodule Aiur.Orchestrator.GithubBudgetPauseTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Orchestrator.{GithubBudgetPause, PushRouting, State}

  setup do
    # Collapse the fleet-wake jitter so timer-based tests run fast and
    # deterministically. This file is async: false, so the override is scoped
    # to this module.
    original_jitter = Application.get_env(:aiur, :github_budget_wake_jitter_ms)
    Application.put_env(:aiur, :github_budget_wake_jitter_ms, 0)

    on_exit(fn ->
      case original_jitter do
        nil -> Application.delete_env(:aiur, :github_budget_wake_jitter_ms)
        value -> Application.put_env(:aiur, :github_budget_wake_jitter_ms, value)
      end
    end)
  end

  defp running_entry(overrides) do
    Map.merge(
      %{
        identifier: "ISSUE-1",
        pid: self(),
        issue: %Aiur.Issue{id: "issue-1", identifier: "ISSUE-1", state: "active"},
        control: %{status: :working, can_interrupt: true}
      },
      overrides
    )
  end

  defp state_with(entry) do
    %State{running: %{"issue-1" => entry}, max_concurrent_agents: 2}
  end

  describe "backoff_ms/1" do
    test "grows exponentially with the consecutive generation and caps at the max" do
      assert GithubBudgetPause.backoff_ms(1) == 0
      assert GithubBudgetPause.backoff_ms(2) == 30_000
      assert GithubBudgetPause.backoff_ms(3) == 60_000
      assert GithubBudgetPause.backoff_ms(4) == 120_000
      assert GithubBudgetPause.backoff_ms(5) == 240_000
      assert GithubBudgetPause.backoff_ms(6) == 480_000
      assert GithubBudgetPause.backoff_ms(7) == 600_000
      assert GithubBudgetPause.backoff_ms(20) == 600_000
    end
  end

  describe "jitter_ms/1" do
    test "returns a bounded per-agent offset" do
      # The module-wide setup zeroes the jitter for fast timers; this test
      # exercises the production offset with an explicit window.
      original_jitter = Application.get_env(:aiur, :github_budget_wake_jitter_ms)
      Application.put_env(:aiur, :github_budget_wake_jitter_ms, 100)

      on_exit(fn ->
        case original_jitter do
          nil -> Application.delete_env(:aiur, :github_budget_wake_jitter_ms)
          value -> Application.put_env(:aiur, :github_budget_wake_jitter_ms, value)
        end
      end)

      assert GithubBudgetPause.max_jitter_ms() == 100

      for identifier <- ["agent-a", "agent-b", "agent-c"] do
        jitter = GithubBudgetPause.jitter_ms(identifier)
        assert is_integer(jitter)
        assert jitter >= 0
        assert jitter < 100
      end
    end
  end

  describe "parse/3 bounded reset window" do
    test "accepts core/graphql holds with a reset inside the broker window" do
      now_ms = System.system_time(:millisecond)

      assert GithubBudgetPause.parse(
               %{reason: "github_budget_hold", resource: "graphql", reset_at_ms: now_ms + 60_000},
               %{},
               now_ms
             ) == %{resource: "graphql", reset_at_ms: now_ms + 60_000, generation: 1}

      # A slightly-elapsed reset (recovery just after the advertised moment)
      # stays on the immediate-recovery path.
      assert GithubBudgetPause.parse(
               %{reason: "github_budget_hold", resource: "core", reset_at_ms: now_ms - 1},
               %{},
               now_ms
             ) == %{resource: "core", reset_at_ms: now_ms - 1, generation: 1}
    end

    test "rejects a reset far in the past or beyond the future window" do
      now_ms = System.system_time(:millisecond)

      assert is_nil(
               GithubBudgetPause.parse(
                 %{reason: "github_budget_hold", resource: "core", reset_at_ms: now_ms - 300_001},
                 %{},
                 now_ms
               )
             )

      assert is_nil(
               GithubBudgetPause.parse(
                 %{reason: "github_budget_hold", resource: "core", reset_at_ms: now_ms + 86_400_001},
                 %{},
                 now_ms
               )
             )
    end

    test "rejects unknown resources and non-integer resets" do
      now_ms = System.system_time(:millisecond)

      assert is_nil(
               GithubBudgetPause.parse(
                 %{reason: "github_budget_hold", resource: "admin", reset_at_ms: now_ms + 60_000},
                 %{},
                 now_ms
               )
             )

      assert is_nil(
               GithubBudgetPause.parse(
                 %{reason: "github_budget_hold", resource: "core", reset_at_ms: "never"},
                 %{},
                 now_ms
               )
             )
    end
  end

  describe "next_generation/2 consecutive window" do
    test "increments while the previous budget pause is still inside the window" do
      now_ms = System.system_time(:millisecond)

      entry = %{
        github_budget_pause_generation: 3,
        github_budget_last_pause_ms: now_ms - 60_000
      }

      assert GithubBudgetPause.next_generation(entry, now_ms) == 4
    end

    test "restarts at generation 1 once the agent has been working past the window" do
      now_ms = System.system_time(:millisecond)

      stale = %{
        github_budget_pause_generation: 3,
        github_budget_last_pause_ms: now_ms - 600_001
      }

      assert GithubBudgetPause.next_generation(stale, now_ms) == 1
      assert GithubBudgetPause.next_generation(%{}, now_ms) == 1
    end
  end

  describe "schedule_expiry/4 wiring" do
    test "schedules a generation-matched expiry message" do
      ref =
        GithubBudgetPause.schedule_expiry(
          "ISSUE-1",
          1,
          System.system_time(:millisecond) - 1
        )

      assert is_reference(ref)
      assert_receive {:github_budget_pause_expired, "ISSUE-1", 1}, 500
    end
  end

  describe "recover_observed/2 fleet wake" do
    test "schedules per-entry wakes instead of resuming synchronously" do
      now_ms = System.system_time(:millisecond)

      entry =
        running_entry(%{
          control: %{status: :paused, can_interrupt: true},
          paused_reason: :github_budget_hold,
          github_budget_pause_generation: 2,
          github_budget_pause: %{resource: "graphql", reset_at_ms: now_ms - 1, generation: 2}
        })

      state = state_with(entry)

      # The fleet recovery signal only schedules wakes; it never resumes in one
      # synchronous pass (that is the stampede this rework removes).
      result = GithubBudgetPause.recover_observed(state, now_ms)

      assert result == state
      refute_received {:resume_agent, _request_id}
      assert_receive {:github_budget_pause_expired, "ISSUE-1", 2}, 500
    end

    test "does not wake entries whose recorded reset is still in the future" do
      now_ms = System.system_time(:millisecond)

      entry =
        running_entry(%{
          control: %{status: :paused, can_interrupt: true},
          paused_reason: :github_budget_hold,
          github_budget_pause_generation: 3,
          github_budget_pause: %{resource: "core", reset_at_ms: now_ms + 60_000, generation: 3}
        })

      state = state_with(entry)

      result = GithubBudgetPause.recover_observed(state, now_ms)
      assert result == state
      refute_received {:github_budget_pause_expired, "ISSUE-1", _generation}
      refute_received {:resume_agent, _request_id}
    end
  end

  describe "escalation" do
    test "emits an operator attention at the escalation generation and is silent otherwise" do
      Publisher.set_tracked_fn(fn _ -> true end)
      topic = "ticket.esc-agent.github-budget.escalation"
      :ok = Exchange.subscribe(topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      entry = %{identifier: "esc-agent", workspace_path: "/tmp/esc", worker_host: "host-1"}

      assert :ok = GithubBudgetPause.emit_escalation_if_needed(entry, 5)
      assert_receive {:event, %{"needs_attention" => true, topic: ^topic}}, 500

      assert :ok = GithubBudgetPause.emit_escalation_if_needed(entry, 4)
      refute_receive {:event, %{topic: ^topic}}, 100
    end
  end

  describe "integration: consecutive pause generation through the pause path" do
    test "a fifth consecutive budget pause reaches the escalation generation" do
      now_ms = System.system_time(:millisecond)

      entry =
        running_entry(%{
          github_budget_pause_generation: 4,
          github_budget_last_pause_ms: now_ms
        })

      result =
        PushRouting.maybe_pause_on_request(state_with(entry), "ISSUE-1", %{
          payload: %{reason: "github_budget_hold", resource: "core", reset_at_ms: now_ms + 60_000}
        })

      assert result.running["issue-1"].github_budget_pause.generation == 5
      assert is_reference(result.running["issue-1"].github_budget_pause_timer)
    end

    test "a replacement pause clears the budget context including the timer" do
      now_ms = System.system_time(:millisecond)

      entry =
        running_entry(%{
          github_budget_pause_generation: 2,
          github_budget_last_pause_ms: now_ms
        })

      budget_paused =
        PushRouting.maybe_pause_on_request(state_with(entry), "ISSUE-1", %{
          payload: %{reason: "github_budget_hold", resource: "core", reset_at_ms: now_ms + 60_000}
        })

      timer_ref = budget_paused.running["issue-1"].github_budget_pause_timer
      assert is_reference(timer_ref)

      cleared = GithubBudgetPause.clear_context(budget_paused.running["issue-1"])
      refute Map.has_key?(cleared, :github_budget_pause)
      refute Map.has_key?(cleared, :github_budget_pause_timer)
      refute Map.has_key?(cleared, :github_budget_pause_generation)
      refute Map.has_key?(cleared, :github_budget_last_pause_ms)

      # Cancelling an already-cancelled timer is a no-op; the entry no longer
      # carries a ref for a stale wake.
      assert GithubBudgetPause.cancel_timer(cleared) == :ok
    end
  end
end
