defmodule Aiur.Claude.AccountMetersTest do
  use ExUnit.Case, async: false

  alias Aiur.Claude.{AccountMeters, MeterTestSupport}
  alias Aiur.Codex.RateLimitAdapter, as: CodexRateLimitAdapter
  alias Aiur.ProviderAccountGeneration
  alias Aiur.ProviderMeters.Store

  @now ~U[2026-07-16 07:00:00Z]

  setup do
    MeterTestSupport.account_meter_context(@now)
  end

  test "malformed observations retain same-generation LKG and a later valid snapshot recovers", %{
    owner: owner,
    store: store,
    session: session,
    binding: binding
  } do
    assert :ok = AccountMeters.handle_notification(session, fixture("rate-limit-subscription.json"), observed_at: @now)
    first = Store.snapshot(store, :claude, :app_server, binding)
    first_generation = ProviderAccountGeneration.lookup(owner, :claude, :app_server, binding).generation
    assert first.auth_mode == :subscription
    assert first.windows["rate-limit"].used_percent == 83
    assert first.health.state == :healthy

    hostile =
      fixture("rate-limit-subscription.json")
      |> put_in(["params", "rate_limit", "account_type"], "api_key")
      |> put_in(["params", "rate_limit", "headers"], %{"authorization" => "secret"})

    assert {:error, :malformed} =
             AccountMeters.handle_notification(session, hostile, observed_at: DateTime.add(@now, 1, :second))

    failed = Store.snapshot(store, :claude, :app_server, binding)
    assert failed.health.state == :stale
    assert failed.health.failure == :malformed
    assert failed.windows["rate-limit"].used_percent == 83
    assert ProviderAccountGeneration.lookup(owner, :claude, :app_server, binding).generation == first_generation

    recovery = put_in(fixture("rate-limit-subscription.json"), ["params", "rate_limit", "used_percent"], 42)
    assert :ok = AccountMeters.handle_notification(session, recovery, observed_at: DateTime.add(@now, 2, :second))
    recovered = Store.snapshot(store, :claude, :app_server, binding)
    assert recovered.health.state == :healthy
    assert recovered.health.failure == nil
    assert recovered.windows["rate-limit"].used_percent == 42
  end

  test "account changes start an empty generation before accepting new facts", %{
    owner: owner,
    store: store,
    session: session,
    binding: binding
  } do
    assert :ok = AccountMeters.handle_notification(session, fixture("rate-limit-subscription.json"), observed_at: @now)
    first_generation = ProviderAccountGeneration.lookup(owner, :claude, :app_server, binding).generation

    assert :ok = AccountMeters.handle_notification(session, fixture("rate-limit-api-key.json"), observed_at: DateTime.add(@now, 1, :second))
    second_generation = ProviderAccountGeneration.lookup(owner, :claude, :app_server, binding).generation
    assert second_generation != first_generation

    current = Store.snapshot(store, :claude, :app_server, binding)
    assert current.provider_account_generation == second_generation
    assert current.auth_mode == :api_key
    assert current.windows["rate-limit"].used_percent == 100
    refute Enum.any?(current.windows, fn {_id, window} -> window.used_percent == 83 end)
  end

  test "Claude and Codex adapter writes remain isolated in the shared store", %{
    owner: owner,
    store: store,
    session: session,
    binding: claude_binding
  } do
    assert :ok = AccountMeters.handle_notification(session, fixture("rate-limit-subscription.json"), observed_at: @now)
    claude_before = Store.snapshot(store, :claude, :app_server, claude_binding)

    assert {:ok, codex_binding} = ProviderAccountGeneration.issue_binding(owner, :codex, :app_server)

    assert {:ok, %{generation: codex_generation}} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, codex_binding,
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )

    assert is_binary(codex_generation)

    assert {:ok, codex_update} =
             CodexRateLimitAdapter.snapshot(
               %{"rateLimits" => %{"primary" => %{"usedPercent" => 7}}},
               codex_binding.binding,
               :subscription,
               @now
             )

    assert {:ok, codex_snapshot} = Store.ingest(store, codex_update)
    assert codex_snapshot.provider == :codex
    assert codex_snapshot.windows["default:primary"].used_percent == 7
    assert Store.snapshot(store, :claude, :app_server, claude_binding) == claude_before
  end

  test "provider-meter ingestion rejection records malformed health", %{session: session} do
    test_pid = self()

    failing_session = %{
      session
      | provider_meter_ingester: fn _update -> {:error, :invalid_provider_meter_update} end,
        provider_meter_failure_recorder: fn failure ->
          send(test_pid, {:meter_failure, failure})
          {:ok, %{}}
        end
    }

    assert {:error, :malformed} =
             AccountMeters.handle_notification(failing_session, fixture("rate-limit-subscription.json"), observed_at: @now)

    assert_received {:meter_failure, %{reason: :malformed, account_generation_binding: binding}}
    assert binding == session.account_generation_binding
  end

  test "failure-recorder rejection is surfaced instead of swallowed", %{session: session} do
    failing_session = %{
      session
      | provider_meter_ingester: fn _update -> {:error, :invalid_provider_meter_update} end,
        provider_meter_failure_recorder: fn _failure -> {:error, :store_unavailable} end
    }

    assert {:error, :provider_meter_failure_unrecorded} =
             AccountMeters.handle_notification(failing_session, fixture("rate-limit-subscription.json"), observed_at: @now)
  end

  test "unknown account classification clears continuity instead of inheriting prior facts", %{
    store: store,
    session: session,
    binding: binding
  } do
    assert :ok = AccountMeters.handle_notification(session, fixture("rate-limit-subscription.json"), observed_at: @now)

    unknown = put_in(fixture("rate-limit-subscription.json"), ["params", "rate_limit", "account_type"], "unknown")

    assert {:error, :unknown_account_generation} =
             AccountMeters.handle_notification(session, unknown, observed_at: DateTime.add(@now, 1, :second))

    current = Store.snapshot(store, :claude, :app_server, binding)
    assert current.provider_account_generation == nil
    assert current.windows == %{}
    assert current.health.failure == :unknown_account_generation
  end

  test "redacted handler details cannot retain correlations or provider payload", %{session: session} do
    assert :ok = AccountMeters.handle_notification(session, fixture("rate-limit-subscription.json"), observed_at: @now)

    wire = AccountMeters.redacted_message() |> Jason.encode!()

    assert Jason.decode!(wire) == %{
             "raw" => nil,
             "payload" => %{"params" => %{}, "method" => "provider_account/rate_limits_changed"}
           }

    for forbidden <- ["synthetic-turn", "synthetic-thread", "used_percent", "source_version", "account_type"] do
      refute String.contains?(wire, forbidden)
    end
  end

  defp fixture(name), do: MeterTestSupport.fixture(name)
end
