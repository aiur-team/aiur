defmodule Aiur.ProviderMeterProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.ProviderMeterProjection
  alias Aiur.ProviderMeterSnapshot

  @now ~U[2026-07-27 12:00:00Z]

  setup do
    name = :"projection_#{System.unique_integer([:positive])}"
    # No PubSub subscription: the tests deliver observations directly so they
    # do not need the app's PubSub running.
    {:ok, pid} = ProviderMeterProjection.start_link(name: name, subscribe?: false, clock: fn -> @now end)
    %{projection: name, pid: pid}
  end

  test "a provider with no observation reads as unknown, not as zero", %{projection: projection} do
    view = ProviderMeterProjection.provider_view(projection, :claude)

    assert view.state == :unknown
    assert view.observed_at == nil
    assert view.age_seconds == nil
    assert view.windows == %{}
    assert view.health.failure == :no_observation
  end

  test "an accepted observation becomes readable with its age", %{projection: projection, pid: pid} do
    send(pid, {:provider_meter_changed, snapshot(:claude, ~U[2026-07-27 11:58:00Z], %{"5h" => %{used_percent: 42}})})

    view = ProviderMeterProjection.provider_view(projection, :claude)

    assert view.state == :observed
    assert view.observed_at == ~U[2026-07-27 11:58:00Z]
    assert view.age_seconds == 120
    assert view.windows == %{"5h" => %{used_percent: 42}}
  end

  # The projection exists so a value survives the session that observed it —
  # that is precisely when an operator opens a surface to decide what to run.
  test "an observation stays readable after its session ends", %{projection: projection, pid: pid} do
    send(pid, {:provider_meter_changed, snapshot(:codex, ~U[2026-07-27 11:00:00Z])})

    view = ProviderMeterProjection.provider_view(projection, :codex)

    assert view.state == :observed
    assert view.age_seconds == 3_600
  end

  test "a failed probe makes an old retained observation stale and records the attempt", %{
    projection: projection,
    pid: pid
  } do
    send(pid, {:provider_meter_changed, snapshot(:codex, ~U[2026-07-24 12:00:00Z], %{"primary" => %{used_percent: 100}})})

    assert :ok =
             ProviderMeterProjection.record_probe_result(
               projection,
               %{provider: :codex, observed?: false, reason: :port_closed},
               @now
             )

    assert :ok =
             ProviderMeterProjection.record_probe_result(
               projection,
               %{provider: :codex, observed?: false, reason: :port_closed},
               DateTime.add(@now, 1, :second)
             )

    view = ProviderMeterProjection.provider_view(projection, :codex)

    assert view.freshness == :stale
    assert view.age_seconds == 259_200
    assert view.health.state == :stale
    assert view.health.failure == :port_closed
    assert view.health.last_attempt_at == DateTime.add(@now, 1, :second)
    assert view.health.consecutive_failures == 2
    assert view.windows["primary"].used_percent == 100
    assert view.windows["primary"].freshness == :stale
  end

  test "providers project independently", %{projection: projection, pid: pid} do
    send(pid, {:provider_meter_changed, snapshot(:claude, ~U[2026-07-27 11:59:00Z])})

    views = ProviderMeterProjection.snapshot(projection)

    assert views.claude.state == :observed
    assert views.codex.state == :unknown
  end

  # PubSub delivery order is not guaranteed, so a late-arriving older
  # observation must not overwrite a newer one.
  test "an older observation never displaces a newer one", %{projection: projection, pid: pid} do
    send(pid, {:provider_meter_changed, snapshot(:claude, ~U[2026-07-27 11:59:00Z])})
    send(pid, {:provider_meter_changed, snapshot(:claude, ~U[2026-07-27 11:00:00Z])})

    assert ProviderMeterProjection.provider_view(projection, :claude).observed_at == ~U[2026-07-27 11:59:00Z]
  end

  test "provider-wide patches retain independently observed meter windows", %{projection: projection, pid: pid} do
    first = %{snapshot(:deepseek, ~U[2026-07-27 11:58:00Z], %{"balance" => %{kind: :credit}}) | update_kind: :patch}
    second = %{snapshot(:deepseek, ~U[2026-07-27 11:59:00Z], %{"concurrency" => %{kind: :rate_limit}}) | update_kind: :patch}

    send(pid, {:provider_meter_changed, first})
    send(pid, {:provider_meter_changed, second})

    assert ProviderMeterProjection.provider_view(projection, :deepseek).windows == %{
             "balance" => %{kind: :credit},
             "concurrency" => %{kind: :rate_limit}
           }
  end

  test "the projection carries no account generation", %{projection: projection, pid: pid} do
    send(pid, {:provider_meter_changed, snapshot(:claude, ~U[2026-07-27 11:59:00Z])})

    view = ProviderMeterProjection.provider_view(projection, :claude)

    refute Map.has_key?(view, :provider_account_generation)

    assert view |> inspect() |> String.contains?("gen-secret-1") == false,
           "the opaque account generation must not reach a consumer view"
  end

  test "the redacted snapshot strips the account generation but keeps the facts", %{projection: projection, pid: pid} do
    send(pid, {:provider_meter_changed, snapshot(:claude, ~U[2026-07-27 11:58:00Z], %{"5h" => %{used_percent: 42}})})

    redacted = ProviderMeterProjection.redacted_snapshot(projection, :claude)

    assert redacted.provider == :claude
    assert redacted.provider_account_generation == nil
    assert redacted.windows == %{"5h" => %{used_percent: 42}}
    assert redacted.observed_at == ~U[2026-07-27 11:58:00Z]
  end

  test "the redacted snapshot of a never-observed provider is the explicit unknown", %{projection: projection} do
    redacted = ProviderMeterProjection.redacted_snapshot(projection, :codex)

    assert redacted.provider == :codex
    assert redacted.provider_account_generation == nil
    assert redacted.windows == %{}
    # Reuses ProviderMeterSnapshot.unknown/2 so the existing presenters keep
    # rendering their established not-available card; its failure reason is
    # that constructor's, not one this module invents.
    assert redacted.health.state == :unavailable
  end

  test "a redacted read of an unavailable projection is unknown, not a crash" do
    redacted = ProviderMeterProjection.redacted_snapshot(:"absent_#{System.unique_integer([:positive])}", :claude)

    assert redacted.provider == :claude
    assert redacted.health.state == :unavailable
  end

  # An observation whose predecessor carried no timestamp must still land —
  # otherwise a provider that first reported without one could never update.
  test "an observation replaces a predecessor that had no timestamp", %{projection: projection, pid: pid} do
    send(pid, {:provider_meter_changed, %{snapshot(:codex, ~U[2026-07-27 11:00:00Z]) | observed_at: nil}})
    send(pid, {:provider_meter_changed, snapshot(:codex, ~U[2026-07-27 11:30:00Z])})

    assert ProviderMeterProjection.provider_view(projection, :codex).observed_at == ~U[2026-07-27 11:30:00Z]
  end

  test "an observation with no timestamp is ignored rather than retained", %{projection: projection, pid: pid} do
    send(pid, {:provider_meter_changed, %{snapshot(:codex, ~U[2026-07-27 11:00:00Z]) | observed_at: nil}})

    assert ProviderMeterProjection.provider_view(projection, :codex).state == :unknown
  end

  test "unrelated messages do not disturb the projection", %{projection: projection, pid: pid} do
    send(pid, :some_unrelated_message)
    send(pid, {:provider_meter_changed, %{provider: :nonsense}})

    assert ProviderMeterProjection.provider_view(projection, :codex).state == :unknown
    assert Process.alive?(pid)
  end

  test "exposes its provider set and backend" do
    assert ProviderMeterProjection.providers() == [:codex, :claude, :kimi, :deepseek, :openrouter, :fake]
    assert ProviderMeterProjection.backend() == :app_server
  end

  # The default-arity reads resolve the app-supervised server rather than
  # requiring every caller to thread one; the CLI and TUI rely on that.
  test "it is supervisable and readable without a server argument" do
    spec = ProviderMeterProjection.child_spec([])

    assert spec.id == ProviderMeterProjection
    assert spec.restart == :permanent

    assert is_map(ProviderMeterProjection.snapshot())
    assert ProviderMeterProjection.provider_view(:codex).provider == :codex
    assert ProviderMeterProjection.redacted_snapshot(:codex).provider == :codex
  end

  test "an anonymous projection can run without a registered name" do
    {:ok, pid} = ProviderMeterProjection.start_link(name: nil, subscribe?: false)

    assert is_pid(pid)
    assert ProviderMeterProjection.snapshot(pid).claude.state == :unknown

    GenServer.stop(pid)
  end

  test "an unavailable projection degrades to unknown rather than raising" do
    views = ProviderMeterProjection.snapshot(:"never_started_#{System.unique_integer([:positive])}")

    assert views.claude.state == :unknown
    assert views.codex.state == :unknown
  end

  defp snapshot(provider, observed_at, windows \\ %{}) do
    %ProviderMeterSnapshot{
      provider: provider,
      backend: :app_server,
      provider_account_generation: "gen-secret-1",
      observed_at: observed_at,
      auth_mode: :subscription,
      freshness: :fresh,
      health: %{state: :healthy, failure: nil, last_observed_at: observed_at, last_source_version: 1},
      windows: windows
    }
  end
end
