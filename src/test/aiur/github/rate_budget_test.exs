defmodule Aiur.GitHub.RateBudgetTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.RateBudget
  alias Aiur.Orchestrator.{Lifecycle, State, TrackerHealth}

  test "parses rate headers case-insensitively and rejects incomplete observations" do
    assert {:ok, %{limit: 5_000, remaining: 500, reset_at: 2_000}} =
             RateBudget.parse_headers(
               %{
                 "X-RateLimit-Limit" => ["5000"],
                 "x-ratelimit-remaining" => ["500"],
                 "X-Ratelimit-Reset" => ["2000"],
                 "X-RateLimit-Resource" => ["core"]
               },
               now_seconds: 1_000
             )

    assert :error = RateBudget.parse_headers(%{"x-ratelimit-remaining" => "10"})
    assert :error = RateBudget.parse_headers(%{"x-ratelimit-limit" => "bad", "x-ratelimit-remaining" => "1", "x-ratelimit-reset" => "2"})
  end

  test "rejects non-REST and implausibly distant reset observations" do
    headers = headers(5_000, 50, 2_000)

    assert :error = RateBudget.parse_headers(Map.put(headers, "x-ratelimit-resource", "graphql"), now_seconds: 1_000)
    assert :error = RateBudget.parse_headers(Map.put(headers, "x-ratelimit-reset", "999999"), now_seconds: 1_000)
    assert :error = RateBudget.parse_headers(headers(5_000, 50, 900), now_seconds: 1_000)
    assert :error = RateBudget.parse_headers(headers(5_000, 5_001, 2_000), now_seconds: 1_000)
  end

  test "GraphQL quota observations do not throttle REST polling" do
    name = Module.concat(__MODULE__, "Budget#{System.unique_integer([:positive])}")
    start_supervised!({RateBudget, name: name})
    now = System.system_time(:second)

    observe(name, 5_000, 50, now + 1_000)
    assert RateBudget.delay_ms(server: name, now_seconds: now) > 0

    response = %{headers: Map.put(headers(5_000, 5_000, now + 2_000), "x-ratelimit-resource", "graphql")}
    assert :ok = RateBudget.observe_response(response, name)
    assert RateBudget.delay_ms(server: name, now_seconds: now) > 0
  end

  test "progressively protects the larger of ten percent or one hundred requests" do
    assert RateBudget.calculate_delay_ms(%{limit: 5_000, remaining: 501, reset_at: 2_000}, 1_000) == 0
    assert RateBudget.calculate_delay_ms(%{limit: 5_000, remaining: 500, reset_at: 2_000}, 1_000) < 10_000
    assert RateBudget.calculate_delay_ms(%{limit: 500, remaining: 100, reset_at: 2_000}, 1_000) < 20_000
    assert RateBudget.calculate_delay_ms(%{limit: 500, remaining: 100, reset_at: 900}, 1_000) == 0
    assert RateBudget.calculate_delay_ms(%{limit: 5_000, remaining: 0, reset_at: 9_000}, 1_000) == :timer.hours(1)
    assert RateBudget.calculate_delay_ms(%{limit: 60, remaining: 60, reset_at: 2_000}, 1_000) == 0
    assert RateBudget.calculate_delay_ms(%{limit: 100, remaining: 100, reset_at: 2_000}, 1_000) == 0
  end

  test "observing a response does not wait for a suspended budget process" do
    name = Module.concat(__MODULE__, "Budget#{System.unique_integer([:positive])}")
    start_supervised!({RateBudget, name: name})
    :sys.suspend(name)

    try do
      task = Task.async(fn -> RateBudget.observe_response(%{headers: headers(5_000, 50, System.system_time(:second) + 1_000)}, name) end)

      assert {:ok, :ok} = Task.yield(task, 500)
    after
      :sys.resume(name)
    end
  end

  test "retains the lowest remaining count in the newest reset window" do
    name = Module.concat(__MODULE__, "Budget#{System.unique_integer([:positive])}")
    start_supervised!({RateBudget, name: name})
    now = System.system_time(:second)

    observe(name, 5_000, 400, now + 1_000)
    observe(name, 5_000, 450, now + 1_000)
    assert RateBudget.delay_ms(server: name, now_seconds: now) > 0

    observe(name, 5_000, 4_000, now + 2_000)
    observe(name, 5_000, 0, now + 1_000)
    assert RateBudget.delay_ms(server: name, now_seconds: now) > 0
  end

  test "a freshly observed smaller reset window clears stale throttling" do
    name = Module.concat(__MODULE__, "Budget#{System.unique_integer([:positive])}")
    start_supervised!({RateBudget, name: name})
    now = System.system_time(:second)

    observe(name, 5_000, 0, now + 3_000)
    assert RateBudget.delay_ms(server: name, now_seconds: now) > 0

    observe(name, 5_000, 5_000, now + 1_000)
    assert RateBudget.delay_ms(server: name, now_seconds: now) == 0
  end

  test "a late expired response does not erase the active budget" do
    name = Module.concat(__MODULE__, "Budget#{System.unique_integer([:positive])}")
    start_supervised!({RateBudget, name: name})
    now = System.system_time(:second)

    observe(name, 5_000, 0, now + 1_000)
    RateBudget.observe_response(%{headers: headers(5_000, 5_000, now - 1)}, name)
    :sys.get_state(name)

    assert RateBudget.delay_ms(server: name, now_seconds: now) > 0
  end

  test "a fresh response recovers through parsing and scheduling after the wall clock moves backward" do
    name = Module.concat(__MODULE__, "Budget#{System.unique_integer([:positive])}")
    start_supervised!({RateBudget, name: name})
    state = %State{poll_interval_ms: 10_000, github_poll_delays: %{}}

    RateBudget.observe_response(%{headers: headers(5_000, 0, 4_700)}, name, now_seconds: 1_000, monotonic_ms: 10_000)
    :sys.get_state(name)

    assert TrackerHealth.next_poll_delay_ms(state,
             budget_delay_fun: fn -> RateBudget.delay_ms(server: name, now_seconds: 699, monotonic_ms: 10_001) end
           ) > 10_000

    RateBudget.observe_response(%{headers: headers(5_000, 5_000, 4_600)}, name, now_seconds: 699, monotonic_ms: 10_001)
    :sys.get_state(name)

    assert 10_000 ==
             TrackerHealth.next_poll_delay_ms(state,
               budget_delay_fun: fn -> RateBudget.delay_ms(server: name, now_seconds: 699, monotonic_ms: 10_001) end
             )
  end

  test "reports non-secret pacing detail while the budget is throttled" do
    name = Module.concat(__MODULE__, "Budget#{System.unique_integer([:positive])}")
    start_supervised!({RateBudget, name: name})

    RateBudget.observe_response(%{headers: headers(5_000, 0, 2_000)}, name, now_seconds: 1_000, monotonic_ms: 10_000)
    :sys.get_state(name)

    assert %{
             reason: :github_rate_budget,
             delay_ms: 1_001_000,
             reset_in_ms: 1_000_000,
             remaining: 0,
             limit: 5_000
           } = RateBudget.status(server: name, now_seconds: 1_000, monotonic_ms: 10_000)
  end

  test "expired observations clear and a missing process degrades to zero" do
    name = Module.concat(__MODULE__, "Budget#{System.unique_integer([:positive])}")
    start_supervised!({RateBudget, name: name})
    now = System.system_time(:second)
    observe(name, 5_000, 0, now + 1_000)

    assert RateBudget.delay_ms(server: name, now_seconds: now + 1_001) == 0
    assert RateBudget.delay_ms(server: name, now_seconds: now) == 0
    assert RateBudget.delay_ms(server: Module.concat(__MODULE__, Missing)) == 0
  end

  test "transport observation through scheduling returns to the normal poll interval" do
    name = Module.concat(__MODULE__, "Budget#{System.unique_integer([:positive])}")
    start_supervised!({RateBudget, name: name})
    now = System.system_time(:second)
    state = %State{poll_interval_ms: 10_000, github_poll_delays: %{}}

    observe(name, 5_000, 0, now + 1_000)

    throttled_delay =
      TrackerHealth.next_poll_delay_ms(state,
        budget_delay_fun: fn -> RateBudget.delay_ms(server: name, now_seconds: now) end
      )

    assert throttled_delay > 10_000

    assert 10_000 =
             TrackerHealth.next_poll_delay_ms(state,
               budget_delay_fun: fn -> RateBudget.delay_ms(server: name, now_seconds: now + 1_001) end
             )

    scheduled = Lifecycle.schedule_tick(state, 10_000)
    assert scheduled.next_poll_due_at_ms > System.monotonic_time(:millisecond) + 9_000
    Process.cancel_timer(scheduled.tick_timer_ref)
  end

  defp observe(name, limit, remaining, reset_at) do
    RateBudget.observe_response(
      %{
        headers: headers(limit, remaining, reset_at)
      },
      name
    )

    :sys.get_state(name)
  end

  defp headers(limit, remaining, reset_at) do
    %{
      "x-ratelimit-limit" => Integer.to_string(limit),
      "x-ratelimit-remaining" => Integer.to_string(remaining),
      "x-ratelimit-reset" => Integer.to_string(reset_at),
      "x-ratelimit-resource" => "core"
    }
  end
end
