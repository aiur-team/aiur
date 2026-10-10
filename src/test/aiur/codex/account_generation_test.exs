defmodule Aiur.Codex.AccountGenerationTest do
  use ExUnit.Case, async: false

  alias Aiur.Codex.{AccountGeneration, RateLimitAdapter}
  alias Aiur.ProviderAccountGeneration
  alias Aiur.ProviderMeters.{Input, Store}

  import Aiur.Codex.AccountGenerationTestSupport

  setup_all do
    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub}, id: {Phoenix.PubSub, Aiur.PubSub})
    end

    :ok
  end

  setup do
    default_context()
  end

  test "account/read seeds the trusted startup binding without retaining identity payloads", %{owner: owner, session: session} do
    raw_identity = "person@example.test credential=super-secret"

    assert :ok =
             AccountGeneration.seed_from_account_read(session, %{auth_mode: "chatgpt"})

    assert snapshot = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)
    assert is_binary(snapshot.generation)
    assert snapshot.source == :codex_app_server
    refute inspect(snapshot) =~ raw_identity
    refute inspect(:sys.get_state(owner)) =~ raw_identity
    refute inspect(:sys.get_state(owner)) =~ "chatgpt"
  end

  test "account updates create a shared generation and emit only a redacted audit message", %{owner: owner, session: session} do
    raw_identity = "person@example.test credential=super-secret"

    payload = %{
      "method" => "account/updated",
      "params" => %{"authMode" => "chatgpt", "email" => raw_identity, "credential" => raw_identity}
    }

    assert {:redacted, details} = AccountGeneration.handle_notification(session, "account/updated", payload)
    assert details == %{payload: %{"method" => "provider_account/authentication_changed", "params" => %{}}, raw: nil}

    assert snapshot = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)
    assert is_binary(snapshot.generation)
    refute inspect(details) =~ raw_identity
    refute inspect(:sys.get_state(owner)) =~ raw_identity
  end

  test "same-mode account updates rotate without explicit continuity proof", %{owner: owner, session: session} do
    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    first = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    repeated = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)
    refute repeated.generation == first.generation

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "apikey"}})

    current = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)
    refute current.generation == repeated.generation
  end

  test "invalid auth modes and absent startup accounts remain explicitly unknown", %{owner: owner, session: session} do
    assert :ok = AccountGeneration.seed_from_account_read(session, %{auth_mode: nil})

    assert %{generation: nil, reason: :no_authenticated_account} =
             ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "unknown-mode"}})

    assert %{generation: nil, reason: :unsupported_auth_mode} =
             ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)
  end

  test "a nullable account update logs out and keeps its reason distinct", %{owner: owner, session: session} do
    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => nil}})

    assert %{generation: nil, reason: :logout} =
             ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)
  end

  test "token refresh and quota updates do not rotate a known binding", %{owner: owner, session: session} do
    parent = self()
    session = Map.put(session, :rate_limit_observer, fn backend, limits -> send(parent, {:rate_limits, backend, limits}) end)

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    first = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    assert {:redacted, %{raw: nil}} =
             AccountGeneration.handle_notification(session, "account/chatgptAuthTokens/refresh", %{"params" => %{}})

    rate_limits = %{"primary" => %{"usedPercent" => 100}}

    assert {:redacted,
            %{
              payload: %{"method" => "provider_account/rate_limits_changed", "params" => %{}},
              raw: nil,
              rate_limits: ^rate_limits
            }} =
             AccountGeneration.handle_notification(session, "account/rateLimits/updated", %{
               "params" => %{"rateLimits" => rate_limits}
             })

    assert_receive {:rate_limits, "codex", ^rate_limits}, 2_000
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding) == first
  end

  test "rate-limit patches share the trusted account generation and preserve LKG on failure", %{owner: owner, session: session} do
    {:ok, meter_store} = Store.start_link(name: nil, account_generation_owner: owner)
    session = Map.put(session, :provider_meter_ingester, &Store.ingest(meter_store, &1))
    session = Map.put(session, :provider_meter_failure_recorder, &Store.record_failure(meter_store, &1))

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    expected_generation = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding).generation

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/rateLimits/updated", %{
               "params" => %{
                 "rateLimits" => %{
                   "limitId" => "codex",
                   "primary" => %{"usedPercent" => 75, "windowDurationMins" => 300}
                 }
               }
             })

    snapshot = Store.snapshot(meter_store, :codex, :app_server, session.account_generation_binding)
    assert snapshot.provider_account_generation == expected_generation
    assert snapshot.auth_mode == :subscription
    assert snapshot.windows["codex:primary"].used_percent == 75

    failure_at = DateTime.add(snapshot.health.last_observed_at, 1, :second)
    assert :ok = AccountGeneration.record_rate_limit_failure(session, :response_timeout, observed_at: failure_at)
    assert stale = Store.snapshot(meter_store, :codex, :app_server, session.account_generation_binding)
    assert stale.provider_account_generation == expected_generation
    assert stale.health.state == :stale
    assert stale.windows["codex:primary"].used_percent == 75

    response = %{
      "rateLimits" => %{
        "limitId" => "codex",
        "primary" => %{"usedPercent" => 20, "windowDurationMins" => 300}
      },
      "rateLimitsByLimitId" => nil,
      "rateLimitResetCredits" => nil
    }

    assert %{"primary" => %{"usedPercent" => 20}} =
             AccountGeneration.observe_rate_limit_snapshot(session, response, observed_at: DateTime.add(failure_at, 1, :second))

    assert recovered = Store.snapshot(meter_store, :codex, :app_server, session.account_generation_binding)
    assert recovered.provider_account_generation == expected_generation
    assert recovered.health.state == :healthy
    assert recovered.windows["codex:primary"].used_percent == 20

    failure = RateLimitAdapter.failure(session.account_generation_binding, :response_timeout, failure_at)
    assert {:ok, _normalized} = Input.normalize_failure(failure)
  end

  test "API-key snapshots keep the trusted generation and auth mode", %{owner: owner, session: session} do
    {:ok, meter_store} = Store.start_link(name: nil, account_generation_owner: owner)
    session = Map.put(session, :provider_meter_ingester, &Store.ingest(meter_store, &1))

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "apikey"}})

    expected_generation = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding).generation

    response = %{
      "rateLimits" => %{"primary" => %{"usedPercent" => 20}},
      "rateLimitsByLimitId" => nil,
      "rateLimitResetCredits" => nil
    }

    assert %{"primary" => %{"usedPercent" => 20}} = AccountGeneration.observe_rate_limit_snapshot(session, response)

    snapshot = Store.snapshot(meter_store, :codex, :app_server, session.account_generation_binding)
    assert snapshot.provider_account_generation == expected_generation
    assert snapshot.auth_mode == :api_key
    assert snapshot.windows["default:primary"].used_percent == 20
  end

  test "an unkeyed patch cannot overwrite a multi-limit canonical snapshot", %{owner: owner, session: session} do
    {:ok, meter_store} = Store.start_link(name: nil, account_generation_owner: owner)

    session =
      session
      |> Map.put(:provider_meter_ingester, &Store.ingest(meter_store, &1))
      |> Map.put(:provider_meter_failure_recorder, &Store.record_failure(meter_store, &1))

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    response = %{
      "rateLimits" => %{"limitId" => "codex", "primary" => %{"usedPercent" => 30}},
      "rateLimitsByLimitId" => %{
        "codex" => %{"limitId" => "codex", "primary" => %{"usedPercent" => 30}},
        "gpt-5" => %{"limitId" => "gpt-5", "primary" => %{"usedPercent" => 40}}
      },
      "rateLimitResetCredits" => nil
    }

    assert is_map(AccountGeneration.observe_rate_limit_snapshot(session, response))

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/rateLimits/updated", %{
               "params" => %{"rateLimits" => %{"primary" => %{"usedPercent" => 90}}}
             })

    snapshot = Store.snapshot(meter_store, :codex, :app_server, session.account_generation_binding)
    assert snapshot.windows["codex:primary"].used_percent == 30
    assert snapshot.windows["gpt-5:primary"].used_percent == 40
    assert snapshot.health.state == :stale
    assert snapshot.health.failure == :malformed
  end

  test "malformed meter updates retain LKG and do not reach scheduling compatibility", %{owner: owner, session: session} do
    {:ok, meter_store} = Store.start_link(name: nil, account_generation_owner: owner)
    parent = self()

    session =
      session
      |> Map.put(:provider_meter_ingester, &Store.ingest(meter_store, &1))
      |> Map.put(:provider_meter_failure_recorder, &Store.record_failure(meter_store, &1))
      |> Map.put(:rate_limit_observer, fn backend, limits -> send(parent, {:rate_limits, backend, limits}) end)

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    valid = %{
      "rateLimits" => %{"primary" => %{"usedPercent" => 100}},
      "rateLimitsByLimitId" => nil,
      "rateLimitResetCredits" => nil
    }

    assert %{"primary" => %{"usedPercent" => 100}} = AccountGeneration.observe_rate_limit_snapshot(session, valid)
    assert_receive {:rate_limits, "codex", %{"primary" => %{"usedPercent" => 100}}}, 1000

    malformed = put_in(valid, ["rateLimits", "primary", "usedPercent"], -1)
    assert nil == AccountGeneration.observe_rate_limit_snapshot(session, malformed)
    refute_receive {:rate_limits, "codex", _}, 100

    snapshot = Store.snapshot(meter_store, :codex, :app_server, session.account_generation_binding)

    assert snapshot.health == %{
             state: :stale,
             failure: :malformed,
             last_attempt_at: nil,
             last_observed_at: snapshot.health.last_observed_at,
             consecutive_failures: 0,
             last_source_version: nil
           }

    assert snapshot.windows["default:primary"].used_percent == 100
  end
end
