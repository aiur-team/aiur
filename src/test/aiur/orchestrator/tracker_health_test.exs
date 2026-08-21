defmodule Aiur.Orchestrator.TrackerHealthTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.{State, TrackerHealth}
  alias Aiur.Webhooks.ModeRegistry

  test "uses the base interval when no GitHub delay is active" do
    state = %State{poll_interval_ms: 1_000, github_poll_delays: %{}, running: %{"issue-1" => %{}}}
    assert TrackerHealth.next_poll_delay_ms(state) == 1_000
  end

  test "uses the largest active GitHub delay" do
    state = %State{poll_interval_ms: 1_000, github_poll_delays: %{comments: 2_000, firehose: 3_000}, running: %{"issue-1" => %{}}}

    assert TrackerHealth.next_poll_delay_ms(state) == 3_000
  end

  test "widens the interval while the fleet is idle" do
    state = %State{
      poll_interval_ms: 120_000,
      github_poll_delays: %{},
      running: %{},
      poll_cycles_completed: 1
    }

    assert TrackerHealth.next_poll_delay_ms(state, idle_widen_factor: 5.0) == 600_000
  end

  test "reads the idle widen factor from configured settings" do
    state = %State{
      poll_interval_ms: 30_000,
      github_poll_delays: %{},
      running: %{},
      poll_cycles_completed: 1
    }

    assert %{delay_ms: 150_000, idle_backoff?: true, idle_widen_factor: 5.0} =
             TrackerHealth.poll_schedule(state)
  end

  test "widens the interval when every parked agent is paused" do
    state = %State{
      poll_interval_ms: 120_000,
      github_poll_delays: %{},
      running: %{
        "issue-1" => %{control: %{status: :paused}},
        "issue-2" => %{control: %{status: :completed}}
      },
      poll_cycles_completed: 1
    }

    assert TrackerHealth.next_poll_delay_ms(state, idle_widen_factor: 5.0) == 600_000
  end

  test "does not widen the interval while an agent is running" do
    state = %State{
      poll_interval_ms: 120_000,
      github_poll_delays: %{},
      running: %{"issue-1" => %{}},
      poll_cycles_completed: 1
    }

    assert TrackerHealth.next_poll_delay_ms(state, idle_widen_factor: 5.0) == 120_000
  end

  test "a factor of one disables idle backoff" do
    state = %State{
      poll_interval_ms: 120_000,
      github_poll_delays: %{},
      running: %{},
      poll_cycles_completed: 1
    }

    assert %{delay_ms: 120_000, idle_backoff?: false} =
             TrackerHealth.poll_schedule(state, idle_widen_factor: 1.0)
  end

  # A freshly started daemon has observed no idleness: it must poll at the base
  # interval first and only back off once a full cycle has run with nothing to
  # do (#2138).
  test "does not widen before the first poll cycle completes" do
    state = %State{poll_interval_ms: 120_000, github_poll_delays: %{}, running: %{}}

    assert %{delay_ms: 120_000, idle_backoff?: false} =
             TrackerHealth.poll_schedule(state, idle_widen_factor: 5.0)
  end

  # A live fleet with claimable tickets is not idle — it simply has not looked.
  # Backing off there is exactly the "idles up to 20 minutes with work waiting"
  # defect, so dispatchable demand keeps the poll at the base interval (#2138).
  test "does not widen while dispatchable work is waiting" do
    issue = %Aiur.Issue{id: "issue-1", identifier: "owner/repo#1", title: "Work", state: "todo", labels: ["agent:todo"]}

    state = %State{
      poll_interval_ms: 120_000,
      github_poll_delays: %{},
      running: %{},
      poll_cycles_completed: 1,
      last_polled_issues: %{"issue-1" => issue}
    }

    assert %{delay_ms: 120_000, idle_backoff?: false} =
             TrackerHealth.poll_schedule(state, idle_widen_factor: 5.0)
  end

  # A globally paused fleet cannot dispatch even with tickets waiting, so it
  # still backs off; unpausing wakes a prompt poll instead (#2138).
  test "widens a paused fleet even with tickets waiting" do
    issue = %Aiur.Issue{id: "issue-1", identifier: "owner/repo#1", title: "Work", state: "todo", labels: ["agent:todo"]}

    state = %State{
      poll_interval_ms: 120_000,
      github_poll_delays: %{},
      running: %{},
      poll_cycles_completed: 1,
      globally_paused: true,
      last_polled_issues: %{"issue-1" => issue}
    }

    assert %{delay_ms: 600_000, idle_backoff?: true} =
             TrackerHealth.poll_schedule(state, idle_widen_factor: 5.0)
  end

  test "idle and webhook widen factors compose before GitHub floors apply" do
    state = %State{
      poll_interval_ms: 120_000,
      github_poll_delays: %{comments: 900_000},
      running: %{},
      poll_cycles_completed: 1
    }

    assert TrackerHealth.next_poll_delay_ms(state,
             repo: "aiur-team/aiur",
             transport: :webhook,
             widen_factor: 2.0,
             idle_widen_factor: 5.0
           ) == 1_200_000
  end

  # GitHub's X-Poll-Interval is a floor ("do not poll faster than this"), not a
  # target. Every successful firehose poll records it — 60s by default — so
  # treating it as the interval outright made `polling.interval_seconds` dead
  # config for any value above 60s, silently defeating the widening this epic
  # exists to deliver.
  test "a configured interval wider than GitHub's floor still wins" do
    state = %State{poll_interval_ms: 120_000, github_poll_delays: %{firehose: 60_000}, running: %{"issue-1" => %{}}}

    assert TrackerHealth.next_poll_delay_ms(state) == 120_000
  end

  test "GitHub's floor still wins when it is wider than the configured interval" do
    state = %State{poll_interval_ms: 30_000, github_poll_delays: %{firehose: 60_000}, running: %{"issue-1" => %{}}}

    assert TrackerHealth.next_poll_delay_ms(state) == 60_000
  end

  test "a rate-limit backoff longer than the configured interval is still respected" do
    state = %State{
      poll_interval_ms: 120_000,
      github_poll_delays: %{firehose: 60_000, comments: 900_000},
      running: %{"issue-1" => %{}}
    }

    assert TrackerHealth.next_poll_delay_ms(state) == 900_000
  end

  # Criterion 5 of #1680: delivery silence past the threshold must raise an
  # alert *and* restore the tighter poll interval automatically. These drive the
  # real `ModeRegistry` rather than stubbing a transport, because the thing worth
  # proving is that the orchestrator's own tick reads the registry the silence
  # sweep writes to — a stubbed transport would pass against a `next_poll_delay_ms`
  # that never consults it.
  describe "webhook-backed widening and automatic restore" do
    @repo "aiur-team/webhook-cutover"

    defp start_registry(opts \\ []) do
      test = self()
      name = :"tracker_health_registry_#{System.unique_integer([:positive])}"

      defaults = [
        name: name,
        configured_repos: [@repo],
        silence_threshold_ms: 900_000,
        sweep_interval_ms: 3_600_000,
        alert_fun: fn alert_name, message, alert_opts ->
          send(test, {:alert, alert_name, message, alert_opts})
          :ok
        end
      ]

      {:ok, _pid} = start_supervised({ModeRegistry, Keyword.merge(defaults, opts)})
      name
    end

    defp at(seconds), do: DateTime.add(~U[2026-08-10 12:00:00Z], seconds, :second)

    defp delay(registry, state),
      do: TrackerHealth.next_poll_delay_ms(state, repo: @repo, server: registry, widen_factor: 2.0, idle_widen_factor: 1.0)

    test "a proven repo widens, silence degrades it, and the base interval comes back" do
      registry = start_registry()
      state = %State{poll_interval_ms: 120_000, github_poll_delays: %{}}

      # Configured but never delivered: full rate, unchanged by this epic.
      assert delay(registry, state) == 120_000

      {:ok, _mode} = ModeRegistry.record_delivery(@repo, server: registry, at: at(0))
      assert delay(registry, state) == 240_000

      # Corroboration: the poller published events the webhook never carried.
      {:ok, _mode} = ModeRegistry.record_activity(@repo, server: registry, at: at(1_000))
      {:ok, [@repo]} = ModeRegistry.sweep(registry, at(2_000))

      assert_received {:alert, "webhook.degraded", message, alert_opts}
      assert message =~ @repo
      assert alert_opts[:needs_attention]

      # The restore is the point: no operator action, no separate code path.
      assert delay(registry, state) == 120_000

      # And a delivery after degradation widens it again.
      {:ok, _mode} = ModeRegistry.record_delivery(@repo, server: registry, at: at(1_001))
      assert_received {:alert, "webhook.recovered", _message, _opts}
      assert delay(registry, state) == 240_000
    end

    test "a GitHub floor wider than the widened interval still wins" do
      registry = start_registry()
      {:ok, _mode} = ModeRegistry.record_delivery(@repo, server: registry, at: at(0))

      state = %State{poll_interval_ms: 120_000, github_poll_delays: %{comments: 900_000}}

      assert delay(registry, state) == 900_000
    end

    test "widening never applies to a repo that only polls" do
      registry = start_registry(configured_repos: [])
      state = %State{poll_interval_ms: 120_000, github_poll_delays: %{}}

      assert delay(registry, state) == 120_000
    end
  end
end
