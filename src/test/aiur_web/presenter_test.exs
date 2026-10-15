defmodule AiurWeb.PresenterTest do
  use Aiur.TestSupport

  alias Aiur.Events.SubscriptionStore
  alias Aiur.{Issue, PollCadence}
  alias Aiur.Orchestrator
  alias AiurWeb.Presenter

  import AiurWeb.PresenterFixtures

  test "projects explicit waiting reasons, staleness, CI/PR, and idle rows" do
    orchestrator_name = Module.concat(__MODULE__, :FleetOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    conversation_handle = "conversation:" <> String.duplicate("B", 43)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    ci_wait_entry =
      "issue-ci-wait"
      |> running_entry("MT-700", :paused, "ci-wait")
      |> Map.put(:paused_reason, :ci_wait)
      |> Map.merge(%{
        agent_input_tokens: 910_011,
        agent_output_tokens: 910_012,
        agent_total_tokens: 910_023,
        telemetry_attempt_id: "attempt-ci-wait",
        context_usage: %{
          session_id: "private-session",
          used_tokens: 1200,
          window_tokens: 4000,
          used_percent: 30.0,
          pressure: :warning,
          view_cursor: "private-cursor"
        },
        live_conversation: %{
          generation_handle: conversation_handle,
          state: :known_empty,
          health: :healthy,
          freshness: :current,
          observed_at: ~U[2026-07-15 10:02:00Z]
        }
      })
      |> put_in([:issue, Access.key(:selected_backend)], "codex")
      |> put_in(
        [:issue, Access.key(:labels)],
        ["model:codex-gpt-5.6-terra", "complexity:3", "build-lane:dashboard-ui"]
      )
      |> Map.put(:session_execution, %{
        backend: "codex",
        requested_model: "gpt-5.6-terra",
        effort: nil
      })
      |> put_in([:issue, Access.key(:tracker_identity)], tracker_identity("MT-700"))

    retry_identity = tracker_identity("MT-701")
    idle_identity = tracker_identity("MT-702")

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{"issue-ci-wait" => ci_wait_entry},
          agent_totals: %{
            input_tokens: 920_011,
            output_tokens: 920_012,
            total_tokens: 920_023,
            seconds_running: 73
          },
          poll_interval_ms: 120_000,
          effective_poll_interval_ms: 600_000,
          idle_poll_backoff: %{active?: true, factor: 5.0},
          agent_rate_limits: %{
            primary: %{remaining_percent: 93, resets_at: "reset-financial-sentinel"}
          },
          retry_attempts: %{
            "mt-701" => %{
              attempt: 1,
              timer_ref: nil,
              due_at_ms: System.monotonic_time(:millisecond) + 5_000,
              identifier: "MT-701",
              tracker_identity: retry_identity
            }
          },
          ci_lifecycle: %{
            state.ci_lifecycle
            | poll_cache: %{
                "MT-700" => %{decision: :pending, pr_number: 55, head_sha: "abc123"},
                "MT-702" => %{decision: :passed, pr_number: 56, head_sha: "def456"}
              }
          },
          last_polled_issues: %{
            "issue-ci-wait" => %Issue{id: "issue-ci-wait", identifier: "MT-700", state: "ci-wait"},
            "mt-701" => %Issue{
              id: "mt-701",
              identifier: "MT-701",
              state: "rework",
              title: "Retrying",
              tracker_identity: retry_identity
            },
            "issue-idle" => %Issue{
              id: "issue-idle",
              identifier: "MT-702",
              state: "human-review",
              title: "Idle review",
              tracker_identity: idle_identity
            }
          }
      }
    end)

    publish_dashboard_snapshot(pid)

    payload = Presenter.state_payload(orchestrator_name, 1_000)

    assert payload.counts == %{running: 1, retrying: 1, idle: 1}
    assert payload.agent_totals == %{seconds_running: 73}

    assert payload.polling == %{
             checking?: false,
             next_poll_in_ms: nil,
             poll_interval_ms: 120_000,
             effective_interval_ms: 600_000,
             idle_backoff: %{active?: true, factor: 5.0},
             class_intervals: PollCadence.effective_intervals()
           }

    refute Map.has_key?(payload, :rate_limits)

    assert [running_row] = payload.running
    refute Map.has_key?(running_row, :tokens)
    assert running_row.issue_identifier == "MT-700"
    assert running_row.title == "Row MT-700"
    assert running_row.url == "https://example.test/issues/MT-700"
    assert running_row.work_state == :paused
    assert running_row.tracker_paused == false
    assert is_integer(running_row.runtime_seconds)
    assert running_row.waiting_reason == :waiting_for_ci
    assert running_row.ci == %{decision: :pending, pr_number: 55, head_sha: "abc123", draft?: false}
    assert running_row.review == :not_started
    assert running_row.open_decision_count == 0
    assert is_integer(running_row.stale_for_seconds)
    assert running_row.tracker_identity == tracker_identity("MT-700")
    refute Map.has_key?(running_row, :telemetry_attempt_id)
    refute Map.has_key?(running_row, :context_usage)
    assert running_row.backend == "codex"
    assert running_row.agent_family == "codex"
    assert running_row.requested_model == "gpt-5.6-terra"
    assert running_row.complexity == 3
    assert "build-lane:dashboard-ui" in running_row.labels

    assert running_row.live_conversation == %{
             generation_handle: conversation_handle,
             state: :known_empty,
             health: :healthy,
             freshness: :current,
             observed_at: ~U[2026-07-15 10:02:00Z]
           }

    assert {:ok, issue_payload} = Presenter.issue_payload("MT-700", orchestrator_name, 5_000)
    refute Map.has_key?(issue_payload.running, :tokens)
    assert issue_payload.running.waiting_reason == :waiting_for_ci
    assert issue_payload.running.live_conversation.generation_handle == conversation_handle

    assert [retry_row] = payload.retrying
    assert retry_row.state == "rework"
    assert retry_row.waiting_reason == :backing_off
    assert retry_row.open_decision_count == 0
    assert retry_row.ci == nil
    assert retry_row.review == :not_started
    assert retry_row.tracker_identity == retry_identity

    assert [idle_row] = payload.idle
    assert idle_row.issue_identifier == "MT-702"
    assert idle_row.waiting_reason == :waiting_for_review
    assert idle_row.ci == %{decision: :passed, pr_number: 56, head_sha: "def456", draft?: false}
    assert idle_row.review == :awaiting
    assert idle_row.tracker_identity == idle_identity
  end

  test "rejects an ambiguous identifier route before projecting nested lifecycle state" do
    orchestrator_name = Module.concat(__MODULE__, :AmbiguousIdentityOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    identifier = "MT-AMBIGUOUS"
    first_identity = %{tracker_identity(identifier) | provider_id: "I_kwDOFirst"}
    second_identity = %{tracker_identity(identifier) | provider_id: "I_kwDOSecond"}

    first =
      "issue-first"
      |> running_entry(identifier, :working)
      |> put_in([:issue, Access.key(:tracker_identity)], first_identity)

    second =
      "issue-second"
      |> running_entry(identifier, :working)
      |> put_in([:issue, Access.key(:tracker_identity)], second_identity)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-first" => first, "issue-second" => second}}
    end)

    publish_dashboard_snapshot(pid)

    assert {:error, :issue_not_found} = Presenter.issue_payload(identifier, orchestrator_name, 1_000)
  end

  test "open_decision_count uses blocking Commands rather than attention chips" do
    orchestrator_name = Module.concat(__MODULE__, :DecisionCountOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    identifier = "MT-800"

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      SubscriptionStore.stop(identifier)
    end)

    :ok = SubscriptionStore.attach(identifier)
    :ok = SubscriptionStore.add_attention(identifier, "needs-review")
    :ok = SubscriptionStore.add_attention(identifier, "optional-question")

    assert {:ok, _} =
             Aiur.DecisionStore.request(%{"question" => "Which release should ship?", "blocking" => true},
               ticket: %{identifier: identifier},
               source: %{agent_id: "worker", session_id: "session", event_id: nil}
             )

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-decision" => running_entry("issue-decision", identifier, :working)}}
    end)

    publish_dashboard_snapshot(pid)

    payload = Presenter.state_payload(orchestrator_name, 1_000)

    assert [running_row] = payload.running
    assert running_row.open_decision_count == 1
    assert running_row.open_decision_count_health == :available
  end

  test "surfaces an active capacity hold with the measured limiting signal and threshold" do
    orchestrator_name = Module.concat(__MODULE__, :CapacityHoldOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    held_at = System.monotonic_time(:millisecond) - 12_000

    :sys.replace_state(pid, fn state ->
      %{
        state
        | capacity_hold: %{
            signal: :load,
            measured: 19.5,
            threshold: 18.0,
            held_since_ms: held_at,
            # Held for 12s but measured 4s ago: the hold was extended by a
            # newer probe. The two numbers must not be conflated (#2527).
            measured_at: DateTime.add(DateTime.utc_now(), -4, :second),
            alerted?: true
          }
      }
    end)

    publish_dashboard_snapshot(pid)

    payload = Presenter.state_payload(orchestrator_name, 1_000)

    assert %{
             held?: true,
             signal: :load,
             measured: 19.5,
             threshold: 18.0,
             held_for_seconds: 12,
             sample_age_seconds: 4
           } = payload.capacity_hold
  end

  test "surfaces an active tracker dispatch hold" do
    orchestrator_name = Module.concat(__MODULE__, :DispatchHoldOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    held_at = System.monotonic_time(:millisecond) - 7_000

    :sys.replace_state(pid, fn state ->
      %{
        state
        | dispatch_hold: %{
            reason: :tracker_preflight,
            detail: :invalid_or_expired_token,
            held_since_ms: held_at
          }
      }
    end)

    publish_dashboard_snapshot(pid)
    payload = Presenter.state_payload(orchestrator_name, 1_000)

    assert %{
             held?: true,
             reason: :tracker_preflight,
             detail: :invalid_or_expired_token,
             held_for_seconds: 7
           } = payload.dispatch_hold
  end

  test "reports a not-held capacity block when no admission hold is active" do
    orchestrator_name = Module.concat(__MODULE__, :NoCapacityHoldOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    publish_dashboard_snapshot(pid)

    payload = Presenter.state_payload(orchestrator_name, 1_000)

    assert %{held?: false, signal: nil, threshold: nil} = payload.capacity_hold
  end
end
