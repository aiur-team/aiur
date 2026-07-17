defmodule Aiur.Claude.RateLimitAdapterTest do
  use ExUnit.Case, async: false

  alias Aiur.Claude.{AccountGeneration, AccountMeters, RateLimitAdapter}
  alias Aiur.ProviderAccountGeneration
  alias Aiur.ProviderMeters.{Input, Reconciler, Store}

  @now ~U[2026-07-16 07:00:00Z]

  setup do
    ensure_pubsub()
    {:ok, owner} = ProviderAccountGeneration.start_link(name: nil, mint: sequence_mint())
    {:ok, store} = Store.start_link(name: nil, account_generation_owner: owner, clock: fn -> @now end)
    account_generation = AccountGeneration.new_binding(owner)

    session = %{
      account_generation_binding: account_generation.binding,
      account_generation_authority: account_generation.authority,
      account_generation_context: account_generation.context,
      account_generation_topic: account_generation.topic,
      account_generation_server: owner,
      provider_meter_ingester: &Store.ingest(store, &1),
      provider_meter_failure_recorder: &Store.record_failure(store, &1)
    }

    %{owner: owner, store: store, session: session, binding: account_generation.binding}
  end

  test "normalizes the pinned subscription notification as one source-backed full observation", %{binding: binding} do
    assert {:ok, update} = RateLimitAdapter.snapshot(fixture("rate-limit-subscription.json"), binding, @now)
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

  test "API-key mode carries only the reported rate control", %{binding: binding} do
    assert {:ok, update} = RateLimitAdapter.snapshot(fixture("rate-limit-api-key.json"), binding, @now)
    assert update.auth_mode == :api_key
    assert update.plan == nil
    assert [window] = update.windows
    assert window.standing == :rejected
    assert window.used_percent == 100
    refute Map.has_key?(window, :credits)
    refute Map.has_key?(window, :spend_control)
    refute Map.has_key?(window, :remaining_percent)
  end

  test "status without numeric quota facts remains honest rather than fabricating a bar", %{binding: binding} do
    payload =
      fixture("rate-limit-subscription.json")
      |> update_in(["params", "rate_limit"], &Map.drop(&1, ["used_percent", "resets_at"]))
      |> put_in(["params", "rate_limit", "status"], "unknown")

    assert {:ok, update} = RateLimitAdapter.snapshot(payload, binding, @now)
    assert [window] = update.windows
    assert window.standing == :unknown
    refute Map.has_key?(window, :used_percent)
    refute Map.has_key?(window, :resets_at)
    assert window.expires_at == DateTime.add(@now, 300, :second)
  end

  test "reset expiry and refresh are independently freshness-aware", %{binding: binding} do
    payload =
      fixture("rate-limit-subscription.json")
      |> put_in(["params", "rate_limit", "resets_at"], DateTime.to_unix(@now) + 30)

    assert {:ok, update} = RateLimitAdapter.snapshot(payload, binding, @now)
    assert {:ok, normalized} = Input.normalize(update)
    reconciler_update = Map.put(normalized, :provider_account_generation, "generation")
    {:updated, snapshot} = Reconciler.apply(nil, Map.delete(reconciler_update, :account_generation_binding), @now)

    assert snapshot.windows["rate-limit"].freshness == :fresh
    expired = Reconciler.refresh(snapshot, DateTime.add(@now, 31, :second))
    assert expired.windows["rate-limit"].freshness == :stale
    assert expired.health.state == :stale
  end

  test "the adapter rejects drift, out-of-range facts, and every non-allowlisted field", %{binding: binding} do
    fixture = fixture("rate-limit-subscription.json")

    invalid = [
      put_in(fixture, ["params", "rate_limit", "source_version"], "unknown"),
      put_in(fixture, ["params", "rate_limit", "source_version"], "9.9"),
      put_in(fixture, ["params", "rate_limit", "status"], "user@example.test secret"),
      put_in(fixture, ["params", "rate_limit", "used_percent"], 101),
      put_in(fixture, ["params", "rate_limit", "resets_at"], -1),
      put_in(fixture, ["params", "rate_limit", "account_type"], "oauth"),
      put_in(fixture, ["params", "rate_limit", "email"], "user@example.test"),
      put_in(fixture, ["params", "credential"], "secret"),
      Map.put(fixture, "raw_response", "secret")
    ]

    for payload <- invalid do
      assert {:error, :malformed} = RateLimitAdapter.snapshot(payload, binding, @now)
    end

    assert {:error, :malformed} = RateLimitAdapter.snapshot(fixture("rate-limit-legacy.json"), binding, @now)

    otel =
      Path.join([__DIR__, "../../fixtures/claude", "telemetry-2.1.210-api-request.json"])
      |> Path.expand()
      |> File.read!()
      |> Jason.decode!()

    assert {:error, :malformed} = RateLimitAdapter.snapshot(otel, binding, @now)
  end

  test "Claude auth observations rotate only when the trusted account mode changes", %{
    owner: owner,
    session: session,
    binding: binding
  } do
    assert {:ok, ^binding} = AccountGeneration.observe(session, :subscription)
    first = ProviderAccountGeneration.lookup(owner, :claude, :app_server, binding)
    assert is_binary(first.generation)

    assert {:ok, ^binding} = AccountGeneration.observe(session, :subscription)
    assert ProviderAccountGeneration.lookup(owner, :claude, :app_server, binding).generation == first.generation

    assert {:ok, ^binding} = AccountGeneration.observe(session, :api_key)
    replacement = ProviderAccountGeneration.lookup(owner, :claude, :app_server, binding)
    assert replacement.generation != first.generation

    assert {:error, :unknown_account_generation} = AccountGeneration.observe(session, :unknown)
    invalidated = ProviderAccountGeneration.lookup(owner, :claude, :app_server, binding)
    assert invalidated.generation == nil
    assert invalidated.reason == :untrusted_lifecycle

    assert {:ok, ^binding} = AccountGeneration.observe(session, :subscription)
    rebound = ProviderAccountGeneration.lookup(owner, :claude, :app_server, binding)
    assert rebound.generation not in [first.generation, replacement.generation]

    assert :ok = AccountGeneration.process_stopped(session)
    assert ProviderAccountGeneration.lookup(owner, :claude, :app_server, binding).generation == nil
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

    api_key = fixture("rate-limit-api-key.json")
    assert :ok = AccountMeters.handle_notification(session, api_key, observed_at: DateTime.add(@now, 1, :second))
    second_generation = ProviderAccountGeneration.lookup(owner, :claude, :app_server, binding).generation
    assert second_generation != first_generation

    current = Store.snapshot(store, :claude, :app_server, binding)
    assert current.provider_account_generation == second_generation
    assert current.auth_mode == :api_key
    assert current.windows["rate-limit"].used_percent == 100
    refute Enum.any?(current.windows, fn {_id, window} -> window.used_percent == 83 end)
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
    payload = fixture("rate-limit-subscription.json")
    assert :ok = AccountMeters.handle_notification(session, payload, observed_at: @now)

    wire = AccountMeters.redacted_message() |> Jason.encode!()

    assert Jason.decode!(wire) == %{
             "raw" => nil,
             "payload" => %{"params" => %{}, "method" => "provider_account/rate_limits_changed"}
           }

    for forbidden <- ["synthetic-turn", "synthetic-thread", "used_percent", "source_version", "account_type"] do
      refute String.contains?(wire, forbidden)
    end
  end

  test "sanctioned fixtures contain no identity, credential, header, endpoint, or raw-response fields" do
    for name <- ["rate-limit-subscription.json", "rate-limit-api-key.json", "rate-limit-legacy.json"] do
      fixture = File.read!(fixture_path(name))

      for forbidden <- ["email", "organization", "account_id", "workspace_id", "credential", "token", "header", "endpoint", "capability", "raw_response"] do
        refute String.contains?(String.downcase(fixture), forbidden), "#{name} contains #{forbidden}"
      end
    end
  end

  defp fixture(name), do: name |> fixture_path() |> File.read!() |> Jason.decode!()
  defp fixture_path(name), do: Path.expand("../../fixtures/claude/#{name}", __DIR__)

  defp ensure_pubsub do
    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end
  end

  defp sequence_mint do
    counter = :counters.new(1, [])

    fn ->
      :counters.add(counter, 1, 1)
      "claude-generation-#{:counters.get(counter, 1)}"
    end
  end
end
