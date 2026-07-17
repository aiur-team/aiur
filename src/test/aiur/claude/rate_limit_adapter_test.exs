defmodule Aiur.Claude.RateLimitAdapterTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.MeterTestSupport
  alias Aiur.Claude.RateLimitAdapter
  alias Aiur.ProviderMeters.{Input, Reconciler}

  @now ~U[2026-07-16 07:00:00Z]

  test "normalizes the pinned subscription notification as one source-backed full observation" do
    assert {:ok, update} = RateLimitAdapter.snapshot(fixture("rate-limit-subscription.json"), make_ref(), @now)
    assert update.provider == :claude
    assert update.backend == :app_server
    assert update.update_kind == :snapshot
    assert update.auth_mode == :subscription
    assert update.plan == nil
    assert update.source == :claude_app_server
    assert update.source_version == 9_009_009

    assert {:ok, normalized} = Input.normalize(update)
    window = normalized.windows["rate-limit"]
    assert window.standing == :allowed_warning
    assert window.used_percent == 83
    assert window.resets_at == ~U[2026-07-16 09:00:00Z]
    assert window.expires_at == DateTime.add(@now, 300, :second)
    refute Map.has_key?(window, :remaining_percent)
    refute Map.has_key?(window, :duration_minutes)
  end

  test "API-key mode carries only the reported rate control" do
    assert {:ok, update} = RateLimitAdapter.snapshot(fixture("rate-limit-api-key.json"), make_ref(), @now)
    assert update.auth_mode == :api_key
    assert update.plan == nil
    assert [window] = update.windows
    assert window.standing == :rejected
    assert window.used_percent == 100
    refute Map.has_key?(window, :credits)
    refute Map.has_key?(window, :spend_control)
    refute Map.has_key?(window, :remaining_percent)
  end

  test "status without numeric quota facts remains honest rather than fabricating a bar" do
    payload =
      fixture("rate-limit-subscription.json")
      |> update_in(["params", "rate_limit"], &Map.drop(&1, ["used_percent", "resets_at"]))
      |> put_in(["params", "rate_limit", "status"], "unknown")

    assert {:ok, update} = RateLimitAdapter.snapshot(payload, make_ref(), @now)
    assert [window] = update.windows
    assert window.standing == :unknown
    refute Map.has_key?(window, :used_percent)
    refute Map.has_key?(window, :resets_at)
    assert window.expires_at == DateTime.add(@now, 300, :second)
  end

  test "reset expiry and refresh are independently freshness-aware" do
    payload =
      fixture("rate-limit-subscription.json")
      |> put_in(["params", "rate_limit", "resets_at"], DateTime.to_unix(@now) + 30)

    assert {:ok, update} = RateLimitAdapter.snapshot(payload, make_ref(), @now)
    assert {:ok, normalized} = Input.normalize(update)
    reconciler_update = Map.put(normalized, :provider_account_generation, "generation")
    {:updated, snapshot} = Reconciler.apply(nil, Map.delete(reconciler_update, :account_generation_binding), @now)

    assert snapshot.windows["rate-limit"].freshness == :fresh
    expired = Reconciler.refresh(snapshot, DateTime.add(@now, 31, :second))
    assert expired.windows["rate-limit"].freshness == :stale
    assert expired.health.state == :stale
  end

  test "the adapter rejects drift, out-of-range facts, and every non-allowlisted field" do
    fixture = fixture("rate-limit-subscription.json")

    invalid = [
      put_in(fixture, ["params", "rate_limit", "source_version"], "unknown"),
      put_in(fixture, ["params", "rate_limit", "source_version"], "9.9"),
      put_in(fixture, ["params", "rate_limit", "status"], "user@example.test secret"),
      put_in(fixture, ["params", "rate_limit", "used_percent"], 101),
      put_in(fixture, ["params", "rate_limit", "resets_at"], -1),
      put_in(fixture, ["params", "rate_limit", "resets_at"], 253_402_300_800),
      put_in(fixture, ["params", "rate_limit", "account_type"], "oauth"),
      Map.put(fixture, "jsonrpc", "1.0"),
      put_in(fixture, ["params", "rate_limit", "email"], "user@example.test"),
      put_in(fixture, ["params", "credential"], "secret"),
      Map.put(fixture, "raw_response", "secret")
    ]

    for payload <- invalid do
      assert {:error, :malformed} = RateLimitAdapter.snapshot(payload, make_ref(), @now)
    end

    assert {:error, :malformed} = RateLimitAdapter.snapshot(fixture("rate-limit-legacy.json"), make_ref(), @now)

    oversized_reset = put_in(fixture, ["params", "rate_limit", "resets_at"], 1.0e308)
    assert {:error, :malformed} = RateLimitAdapter.snapshot(oversized_reset, make_ref(), @now)

    otel =
      Path.join([__DIR__, "../../fixtures/claude", "telemetry-2.1.210-api-request.json"])
      |> Path.expand()
      |> File.read!()
      |> Jason.decode!()

    assert {:error, :malformed} = RateLimitAdapter.snapshot(otel, make_ref(), @now)
  end

  test "sanctioned fixtures contain no identity, credential, header, endpoint, or raw-response fields" do
    for name <- ["rate-limit-subscription.json", "rate-limit-api-key.json", "rate-limit-legacy.json"] do
      fixture = File.read!(MeterTestSupport.fixture_path(name))

      for forbidden <- ["email", "organization", "account_id", "workspace_id", "credential", "token", "header", "endpoint", "capability", "raw_response"] do
        refute String.contains?(String.downcase(fixture), forbidden), "#{name} contains #{forbidden}"
      end
    end
  end

  defp fixture(name), do: MeterTestSupport.fixture(name)
end
