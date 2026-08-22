defmodule Aiur.ModelAvailabilityTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema.Agent
  alias Aiur.ModelAvailability

  setup do
    path = Path.join(System.tmp_dir!(), "aiur-model-usage-#{System.pid()}-#{System.unique_integer([:positive])}.json")
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
end
