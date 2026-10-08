defmodule Aiur.ModelAvailabilityTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema.Agent
  alias Aiur.ModelAvailability

  setup do
    path = Aiur.TestSupport.tmp_root!("aiur-model-usage") <> ".json"
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "persists hourly, weekly, and monthly windows with reset times", %{path: path} do
    reset = DateTime.add(DateTime.utc_now(), 3_600, :second) |> DateTime.to_iso8601()

    assert :ok =
             ModelAvailability.observe(
               "codex",
               %{
                 hourly: %{used: 10, limit: 10, reset_at: reset},
                 weekly: %{used: 4, limit: 20, reset_at: reset},
                 monthly: %{used: 5, limit: 100, reset_at: reset}
               },
               path: path
             )

    assert %{"backends" => %{"codex" => %{"hourly" => %{"used" => 10, "reset_at" => ^reset}}}} = ModelAvailability.load(path)
    refute ModelAvailability.available?("codex", path: path)
  end

  test "normalizes provider primary and secondary windows", %{path: path} do
    reset = DateTime.add(DateTime.utc_now(), 3_600, :second) |> DateTime.to_iso8601()

    assert :ok =
             ModelAvailability.observe(
               "codex",
               %{
                 primary: %{usedPercent: 100, windowDurationMins: 60, resetsAt: reset},
                 secondary: %{usedPercent: 20, windowDurationMins: 10_080, resetsAt: reset}
               },
               path: path
             )

    assert %{"backends" => %{"codex" => %{"hourly" => %{"used" => 100, "limit" => 100}, "weekly" => %{"used" => 20}}}} = ModelAvailability.load(path)
  end

  test "restores availability after the limiting reset", %{path: path} do
    past = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.to_iso8601()
    assert :ok = ModelAvailability.mark_limited("claude", past, path: path)
    assert ModelAvailability.available?("claude", path: path)
    assert ModelAvailability.recovery_confirmed?("claude", path: path)
  end

  test "a refusal after a positive availability observation starts a new streak", %{path: path} do
    now = ~U[2026-09-18 09:20:37Z]
    reset = DateTime.add(now, 3_600, :second) |> DateTime.to_iso8601()

    assert :ok = ModelAvailability.mark_limited("codex", reset, path: path, now: now)

    assert :ok =
             ModelAvailability.observe("codex", %{hourly: %{used: 40, limit: 100}},
               path: path,
               now: DateTime.add(now, 60, :second)
             )

    assert :ok =
             ModelAvailability.mark_limited("codex", reset,
               path: path,
               now: DateTime.add(now, 120, :second)
             )

    entry = get_in(ModelAvailability.load(path), ["backends", "codex"])
    assert entry["limit_streak"] == 1
    refute Map.has_key?(entry, "backoff_until")
  end

  test "chooses the first available backend in configured priority", %{path: path} do
    future = DateTime.add(DateTime.utc_now(), 3_600, :second) |> DateTime.to_iso8601()
    assert :ok = ModelAvailability.mark_limited("claude", future, path: path)
    assert ModelAvailability.first_available(["claude", "codex", "claude-repl"], path: path) == "codex"
  end

  test "normalizes the claude remote-control transport backend", %{path: path} do
    assert ModelAvailability.backend_key("claude-repl") == "claude"
    assert ModelAvailability.backend_key("claude") == "claude"

    now = ~U[2026-07-31 12:00:00Z]
    future = DateTime.add(now, 3_600, :second) |> DateTime.to_iso8601()
    assert :ok = ModelAvailability.mark_limited("claude-repl", future, path: path, now: now)
    refute ModelAvailability.available?("claude", path: path, now: now)
    refute ModelAvailability.available?("claude-repl", path: path, now: now)

    past = DateTime.add(now, -1, :second) |> DateTime.to_iso8601()
    observed_at = DateTime.add(now, 1, :second)

    assert :ok =
             ModelAvailability.observe("claude", %{primary: %{usedPercent: 0, windowDurationMins: 60, resetsAt: past}},
               path: path,
               now: observed_at
             )

    assert ModelAvailability.recovery_confirmed?("claude-repl", path: path, now: observed_at)
  end

  test "validates fallback backend configuration" do
    valid = Agent.changeset(%Agent{}, %{"switch_model_on_ratelimit" => ["claude", "codex"]})
    assert valid.valid?

    duplicate = Agent.changeset(%Agent{}, %{"switch_model_on_ratelimit" => ["codex", "codex"]})
    refute duplicate.valid?

    unknown = Agent.changeset(%Agent{}, %{"switch_model_on_ratelimit" => ["unknown"]})
    refute unknown.valid?
  end

  test "fails open for unreadable state and unsupported provider payloads", %{path: path} do
    File.write!(path, "not json")
    assert %{"backends" => %{}} = ModelAvailability.load(path)
    assert ModelAvailability.available?("codex", path: path)

    assert :ok = ModelAvailability.observe("codex", nil, path: path)
    assert ModelAvailability.available?("codex", path: path)
  end

  test "an explicit limit without a reset remains unavailable", %{path: path} do
    assert :ok = ModelAvailability.mark_limited("codex", nil, path: path)
    refute ModelAvailability.available?("codex", path: path)
  end

  test "uses the active workflow directory for the default ledger path" do
    assert String.ends_with?(ModelAvailability.path(), "model-usage.json")
  end

  test "a past usage-window reset restores availability", %{path: path} do
    reset = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.to_iso8601()

    assert :ok =
             ModelAvailability.observe(
               "codex",
               %{monthly: %{used: 100, limit: 100, reset_at: reset}},
               path: path
             )

    assert ModelAvailability.available?("codex", path: path)
    assert ModelAvailability.recovery_confirmed?("codex", path: path)
  end

  test "merges partial observations without losing a limited window", %{path: path} do
    reset = DateTime.add(DateTime.utc_now(), 3_600, :second) |> DateTime.to_iso8601()
    assert :ok = ModelAvailability.observe("codex", %{weekly: %{used: 10, limit: 10, reset_at: reset}}, path: path)
    assert :ok = ModelAvailability.observe("codex", %{hourly: %{used: 1, limit: 10, reset_at: reset}}, path: path)

    refute ModelAvailability.available?("codex", path: path)
  end

  test "expires an explicit limit with no reset after the fallback ttl", %{path: path} do
    old = DateTime.add(DateTime.utc_now(), -3_601, :second)
    assert :ok = ModelAvailability.mark_limited("codex", nil, path: path, now: old)
    assert ModelAvailability.available?("codex", path: path)
    refute ModelAvailability.recovery_confirmed?("codex", path: path)
  end

  test "a positive observation from before an unknown limit cannot confirm recovery", %{path: path} do
    available_at = DateTime.add(DateTime.utc_now(), -7_202, :second)
    limited_at = DateTime.add(available_at, 1, :second)

    assert :ok =
             ModelAvailability.observe(
               "codex",
               %{hourly: %{used: 1, limit: 10}},
               path: path,
               now: available_at
             )

    assert :ok = ModelAvailability.mark_limited("codex", nil, path: path, now: limited_at)
    assert ModelAvailability.available?("codex", path: path)
    refute ModelAvailability.recovery_confirmed?("codex", path: path)
  end

  test "a limit at the same timestamp supersedes a positive observation", %{path: path} do
    observed_at = DateTime.add(DateTime.utc_now(), -3_601, :second)

    assert :ok =
             ModelAvailability.observe(
               "codex",
               %{hourly: %{used: 1, limit: 10}},
               path: path,
               now: observed_at
             )

    assert :ok = ModelAvailability.mark_limited("codex", nil, path: path, now: observed_at)
    assert ModelAvailability.available?("codex", path: path)
    refute ModelAvailability.recovery_confirmed?("codex", path: path)
  end

  test "confirms recovery after a positive observation newer than the limit", %{path: path} do
    now = DateTime.utc_now()
    assert :ok = ModelAvailability.mark_limited("codex", nil, path: path, now: now)

    assert :ok =
             ModelAvailability.observe(
               "codex",
               %{hourly: %{used: 1, limit: 10}},
               path: path,
               now: DateTime.add(now, 1, :second)
             )

    assert ModelAvailability.recovery_confirmed?("codex", path: path)
  end

  test "does not treat an estimated window reset as confirmed recovery", %{path: path} do
    observed_at = DateTime.utc_now()

    assert :ok =
             ModelAvailability.observe(
               "codex",
               %{hourly: %{used: 10, limit: 10}},
               path: path,
               now: observed_at
             )

    after_estimate = DateTime.add(observed_at, 3_601, :second)
    assert ModelAvailability.available?("codex", path: path, now: after_estimate)
    refute ModelAvailability.recovery_confirmed?("codex", path: path, now: after_estimate)
  end

  test "uses percentage units when both percentage and count fields are present", %{path: path} do
    reset = DateTime.add(DateTime.utc_now(), 3_600, :second) |> DateTime.to_iso8601()

    assert :ok =
             ModelAvailability.observe(
               "codex",
               %{hourly: %{usedPercent: 50, used: 500, limit: 1_000, reset_at: reset}},
               path: path
             )

    assert ModelAvailability.available?("codex", path: path)
  end

  test "gives an exhausted window without reset a bounded fallback deadline", %{path: path} do
    assert :ok = ModelAvailability.observe("codex", %{hourly: %{used: 10, limit: 10}}, path: path)
    refute ModelAvailability.available?("codex", path: path)
  end

  describe "a fleet-wide limit and the repeat backoff" do
    # The 2026-09-26 khala incident, replayed from telemetry. Nineteen agents
    # met one Claude account limit between 02:01:13Z and 02:42:17Z, and every
    # refusal printed the same reset, 03:40:00Z. Each refusal was counted as a
    # repeat of the last, so the streak reached 19, the hold hit its one-hour
    # cap, and `backoff_until` was re-armed from the final straggler to
    # 03:42:17Z -- past the reset the provider had already given us.
    @reset ~U[2026-09-26 03:40:00Z]
    @first_refusal ~U[2026-09-26 02:01:13Z]
    @last_refusal ~U[2026-09-26 02:42:17Z]

    defp refuse_fleet(path) do
      first = DateTime.to_unix(@first_refusal)
      last = DateTime.to_unix(@last_refusal)
      step = div(last - first, 18)

      for index <- 0..18 do
        at = DateTime.from_unix!(min(first + index * step, last))
        assert :ok = ModelAvailability.mark_limited("claude", DateTime.to_iso8601(@reset), path: path, now: at)
      end
    end

    test "concurrent refusals of one limit do not hold the backend past its reset", %{path: path} do
      refuse_fleet(path)

      entry = get_in(ModelAvailability.load(path), ["backends", "claude"])
      assert entry["reset_at"] == DateTime.to_iso8601(@reset)
      assert entry["limit_streak"] == 1
      refute Map.has_key?(entry, "backoff_until")

      refute ModelAvailability.available?("claude", path: path, now: DateTime.add(@reset, -1))
      assert ModelAvailability.available?("claude", path: path, now: @reset)
      assert ModelAvailability.recovery_confirmed?("claude", path: path, now: @reset)
    end

    test "a refusal at or after the printed reset still backs off (#2737)", %{path: path} do
      refuse_fleet(path)

      # The provider lied: it refuses again once its own reset has arrived.
      assert :ok = ModelAvailability.mark_limited("claude", DateTime.to_iso8601(@reset), path: path, now: @reset)

      entry = get_in(ModelAvailability.load(path), ["backends", "claude"])
      assert entry["limit_streak"] == 2
      assert entry["backoff_until"] == DateTime.to_iso8601(DateTime.add(@reset, 600))

      refute ModelAvailability.available?("claude", path: path, now: DateTime.add(@reset, 599))
      assert ModelAvailability.available?("claude", path: path, now: DateTime.add(@reset, 600))
    end
  end

  describe "stale detection and retry scheduling" do
    test "provider hold details disclose freshness, observation, and next probe", %{path: path} do
      now = DateTime.utc_now()
      observed_at = DateTime.add(now, -301, :second)
      retry_at = DateTime.add(now, 120, :second) |> DateTime.to_iso8601()

      assert :ok = ModelAvailability.observe("codex", %{hourly: %{used: 10, limit: 10}}, path: path, now: observed_at)
      assert :ok = ModelAvailability.schedule_retry("codex", now, path: path)

      detail = ModelAvailability.provider_freshness_detail(["codex"], path: path, now: now)
      assert detail =~ "codex=stale"
      assert detail =~ DateTime.to_iso8601(observed_at)
      assert detail =~ retry_at
    end

    test "does not claim an unscheduled probe is happening now", %{path: path} do
      now = DateTime.utc_now()
      observed_at = DateTime.add(now, -301, :second)

      assert :ok = ModelAvailability.observe("codex", %{hourly: %{used: 10, limit: 10}}, path: path, now: observed_at)

      assert ModelAvailability.provider_freshness_detail(["codex"], path: path, now: now) =~
               "next_probe=unknown"
    end

    test "detects stale limits (> 5 minutes old)", %{path: path} do
      now = DateTime.utc_now()
      fresh_time = DateTime.add(now, -60, :second)
      stale_time = DateTime.add(now, -301, :second)

      # Fresh observation
      assert :ok = ModelAvailability.observe("codex", %{hourly: %{used: 5, limit: 10}}, path: path, now: fresh_time)
      refute ModelAvailability.stale?("codex", path: path, now: now)

      # Stale observation
      assert :ok = ModelAvailability.observe("claude", %{hourly: %{used: 5, limit: 10}}, path: path, now: stale_time)
      assert ModelAvailability.stale?("claude", path: path, now: now)
    end

    test "schedules and clears retry", %{path: path} do
      now = DateTime.utc_now()

      # No retry initially
      assert :ok = ModelAvailability.observe("codex", %{hourly: %{used: 5, limit: 10}}, path: path, now: now)
      refute ModelAvailability.retry_scheduled?("codex", path: path, now: now)

      # Schedule retry (will be due in 2 minutes)
      assert :ok = ModelAvailability.schedule_retry("codex", now, path: path)
      # Retry is pending but not yet due
      refute ModelAvailability.retry_scheduled?("codex", path: path, now: now)

      # Retry time is 2 minutes in future - still not due
      future = DateTime.add(now, 119, :second)
      refute ModelAvailability.retry_scheduled?("codex", path: path, now: future)

      # At retry time (2 minutes later), retry is now due
      future_past = DateTime.add(now, 120, :second)
      assert ModelAvailability.retry_scheduled?("codex", path: path, now: future_past)

      # Clear retry schedule
      assert :ok = ModelAvailability.clear_retry_schedule("codex", path: path)
      refute ModelAvailability.retry_scheduled?("codex", path: path, now: future_past)
    end

    test "triggers probes for stale limits", %{path: path} do
      now = DateTime.utc_now()
      stale_time = DateTime.add(now, -301, :second)
      fresh_time = DateTime.add(now, -60, :second)

      # Setup: stale Codex, fresh Claude, and a non-Codex backend.
      assert :ok = ModelAvailability.observe("codex", %{hourly: %{used: 10, limit: 10}}, path: path, now: stale_time)
      assert :ok = ModelAvailability.observe("claude", %{hourly: %{used: 5, limit: 10}}, path: path, now: fresh_time)
      assert :ok = ModelAvailability.observe("openrouter", %{hourly: %{used: 10, limit: 10}}, path: path, now: stale_time)
      assert :ok = ModelAvailability.schedule_retry("codex", now, path: path)

      # Probe stale limits (only Codex is eligible).
      state = ModelAvailability.load(path)
      backends = ["codex", "claude", "openrouter"]

      # Codex has a pending retry that is not due yet, so it is not probed.
      # Claude is fresh and OpenRouter must never use the Codex prober.
      count = ModelAvailability.probe_stale_limits(backends, state: state, now: now, path: path)
      assert count == 0

      due_state = ModelAvailability.load(path)
      due_now = DateTime.add(now, 120, :second)
      assert ModelAvailability.probe_stale_limits(backends, state: due_state, now: due_now, path: path) == 1

      # Claiming a due probe advances retry before spawn, preventing every-tick duplication.
      assert ModelAvailability.probe_stale_limits(backends, state: ModelAvailability.load(path), now: due_now, path: path) == 0
    end
  end

  describe "stale limit refresh integration" do
    test "cached 100% limit refreshes to 4% through the provider prober", %{path: path} do
      now = DateTime.utc_now()
      stale_time = DateTime.add(now, -301, :second)

      # Setup: cached limit at 100% from 5+ minutes ago (stale)
      reset_time = DateTime.add(now, 3600, :second) |> DateTime.to_iso8601()

      assert :ok =
               ModelAvailability.observe(
                 "codex",
                 %{hourly: %{usedPercent: 100, windowDurationMins: 60, resetsAt: reset_time}},
                 path: path,
                 now: stale_time
               )

      # Verify dispatch would be blocked by the 100% limit
      refute ModelAvailability.available?("codex", path: path, now: now)

      assert :ok =
               Aiur.CodexProber.probe_sync("codex", now,
                 path: path,
                 fetch_limits_fun: fn ->
                   {:ok,
                    %{
                      "rateLimits" => %{
                        "primary" => %{
                          "usedPercent" => 4,
                          "windowDurationMins" => 60,
                          "resetsAt" => DateTime.to_unix(DateTime.add(now, 3600, :second))
                        }
                      }
                    }}
                 end
               )

      # After refresh, dispatch should be allowed (4% < 100% limit)
      assert ModelAvailability.available?("codex", path: path, now: now)

      # Verify observation timestamp is fresh
      refute ModelAvailability.stale?("codex", path: path, now: now)
    end

    test "probe failure retains cached reading and schedules retry", %{path: path} do
      now = DateTime.utc_now()
      stale_time = DateTime.add(now, -301, :second)

      # Setup: cached limit at 100% from 5+ minutes ago (stale)
      reset_time = DateTime.add(now, 3600, :second) |> DateTime.to_iso8601()

      assert :ok =
               ModelAvailability.observe(
                 "codex",
                 %{hourly: %{usedPercent: 100, windowDurationMins: 60, resetsAt: reset_time}},
                 path: path,
                 now: stale_time
               )

      # Dispatch is blocked
      refute ModelAvailability.available?("codex", path: path, now: now)

      assert {:error, :provider_unavailable} =
               Aiur.CodexProber.probe_sync("codex", now,
                 path: path,
                 fetch_limits_fun: fn -> {:error, :provider_unavailable} end
               )

      # Cached reading is still there (not cleared by failure)
      refute ModelAvailability.available?("codex", path: path, now: now)

      # Retry is not due yet
      refute ModelAvailability.retry_scheduled?("codex", path: path, now: now)

      # But retry will be due in 2 minutes
      retry_time = DateTime.add(now, 120, :second)
      assert ModelAvailability.retry_scheduled?("codex", path: path, now: retry_time)
    end
  end
end
