defmodule Aiur.Codex.AccountGenerationMeterTest do
  use ExUnit.Case, async: false

  alias Aiur.Codex.{AccountGeneration, RateLimitAdapter}
  alias Aiur.{ModelAvailability, ProviderAccountGeneration}
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

  test "missing rate-limit notification facts mark canonical health stale", %{owner: owner, session: session} do
    {:ok, meter_store} = Store.start_link(name: nil, account_generation_owner: owner)

    session =
      session
      |> Map.put(:provider_meter_ingester, &Store.ingest(meter_store, &1))
      |> Map.put(:provider_meter_failure_recorder, &Store.record_failure(meter_store, &1))

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    response = %{
      "rateLimits" => %{"primary" => %{"usedPercent" => 50}},
      "rateLimitsByLimitId" => nil,
      "rateLimitResetCredits" => nil
    }

    assert is_map(AccountGeneration.observe_rate_limit_snapshot(session, response))

    assert {:redacted, %{raw: nil}} =
             AccountGeneration.handle_notification(session, "account/rateLimits/updated", %{"params" => %{}})

    snapshot = Store.snapshot(meter_store, :codex, :app_server, session.account_generation_binding)
    assert snapshot.health.state == :stale
    assert snapshot.health.failure == :malformed
    assert snapshot.windows["default:primary"].used_percent == 50
  end

  test "rejected ProviderMeters input preserves LKG and marks malformed health", %{owner: owner, session: session} do
    {:ok, meter_store} = Store.start_link(name: nil, account_generation_owner: owner)

    session =
      session
      |> Map.put(:provider_meter_ingester, &Store.ingest(meter_store, &1))
      |> Map.put(:provider_meter_failure_recorder, &Store.record_failure(meter_store, &1))

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    valid = %{
      "rateLimits" => %{"primary" => %{"usedPercent" => 40}},
      "rateLimitsByLimitId" => nil,
      "rateLimitResetCredits" => nil
    }

    assert is_map(AccountGeneration.observe_rate_limit_snapshot(session, valid))

    rejected = put_in(valid, ["rateLimitResetCredits"], %{"availableCount" => 1_000_000_000_001})
    assert nil == AccountGeneration.observe_rate_limit_snapshot(session, rejected)

    snapshot = Store.snapshot(meter_store, :codex, :app_server, session.account_generation_binding)
    assert snapshot.health.state == :stale
    assert snapshot.health.failure == :malformed
    assert snapshot.windows["default:primary"].used_percent == 40
  end

  @tag :tmp_dir
  test "scheduling compatibility cannot overwrite the canonical meter", %{owner: owner, session: session, tmp_dir: tmp_dir} do
    {:ok, meter_store} = Store.start_link(name: nil, account_generation_owner: owner)

    session =
      session
      |> Map.put(:provider_meter_ingester, &Store.ingest(meter_store, &1))
      |> Map.put(:provider_meter_failure_recorder, &Store.record_failure(meter_store, &1))

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    response = %{
      "rateLimits" => %{"primary" => %{"usedPercent" => 100}},
      "rateLimitsByLimitId" => nil,
      "rateLimitResetCredits" => nil
    }

    assert is_map(AccountGeneration.observe_rate_limit_snapshot(session, response))
    canonical = Store.snapshot(meter_store, :codex, :app_server, session.account_generation_binding)

    ModelAvailability.observe("codex", %{"limited" => false}, path: Path.join(tmp_dir, "model-usage.json"))

    assert Store.snapshot(meter_store, :codex, :app_server, session.account_generation_binding) == canonical
  end

  test "late compatibility notifications cannot schedule after continuity is lost", %{session: session} do
    parent = self()
    session = Map.put(session, :rate_limit_observer, fn backend, limits -> send(parent, {:rate_limits, backend, limits}) end)

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/futureLifecycle", %{"params" => %{}})

    assert {:redacted, %{raw: nil}} =
             AccountGeneration.handle_notification(session, "account/rateLimits/updated", %{
               "params" => %{"rateLimits" => %{"limited" => false}}
             })

    refute_receive {:rate_limits, "codex", _}, 100
  end

  test "unrecognized account notifications invalidate and redact provider payloads", %{owner: owner, session: session} do
    assert :ok =
             AccountGeneration.seed_from_account_read(session, %{auth_mode: "chatgpt"})

    assert {:redacted, details} =
             AccountGeneration.handle_notification(session, "account/futureLifecycle", %{
               "params" => %{"email" => "person@example.test", "credential" => "super-secret"}
             })

    assert details == %{payload: %{"method" => "provider_account/unknown_lifecycle", "params" => %{}}, raw: nil}

    assert %{generation: nil, reason: :untrusted_lifecycle} =
             ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    refute inspect(details) =~ "person@example.test"
    refute inspect(:sys.get_state(owner)) =~ "person@example.test"
  end

  test "process teardown loses continuity and owner outages do not prevent cleanup", %{owner: owner, session: session} do
    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    assert :ok = AccountGeneration.process_stopped(session)

    assert %{generation: nil, reason: :continuity_lost} =
             ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    assert %{generation: nil, reason: :continuity_lost} =
             ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    GenServer.stop(owner)

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})
  end

  test "process teardown revokes a copied session before another process can rebind it", %{owner: owner, session: session} do
    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    original = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)
    copied_session = Map.delete(session, :account_generation_context)

    assert :ok = AccountGeneration.process_stopped(session)

    parent = self()

    spawn(fn ->
      result =
        AccountGeneration.handle_notification(copied_session, "account/updated", %{
          "params" => %{"authMode" => "chatgpt"}
        })

      send(parent, {:copied_session_result, result})
    end)

    assert_receive {:copied_session_result, {:redacted, _}}, 2_000

    assert %{generation: nil, reason: :continuity_lost} =
             ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    refute ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding).generation == original.generation
  end

  test "trusted authenticated evidence restores the binding retained by session consumers after its owner restarts" do
    name = :provider_account_generation_restart_test
    mint = sequence_mint()
    {:ok, owner} = ProviderAccountGeneration.start_link(name: name, mint: mint)

    on_exit(fn -> stop_named_owner(name) end)

    session = session_for(name)

    assert :ok = ProviderAccountGeneration.subscribe(owner, :codex, :app_server, session.account_generation_binding)

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    assert_receive {:provider_account_generation_changed, %{change: :bound, generation: original_generation}}, 2_000

    assert is_binary(original_generation)

    GenServer.stop(owner)
    {:ok, replacement_owner} = ProviderAccountGeneration.start_link(name: name, mint: mint)

    assert %{generation: nil, reason: :never_observed} =
             ProviderAccountGeneration.lookup(
               replacement_owner,
               :codex,
               :app_server,
               session.account_generation_binding
             )

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    assert_receive {:provider_account_generation_changed, recovered}, 2_000
    assert %{change: :recovered, generation: nil, reason: :never_observed} = recovered

    assert %{generation: recovered_generation, source: :codex_app_server} =
             ProviderAccountGeneration.lookup(
               replacement_owner,
               :codex,
               :app_server,
               session.account_generation_binding
             )

    assert is_binary(recovered_generation)
    refute recovered_generation == original_generation
    assert_receive {:provider_account_generation_changed, %{change: :bound, generation: ^recovered_generation}}, 2_000
  end

  test "every post-restart lifecycle transition recovers the retained topic before publishing" do
    teardown_transition =
      {:account_generation_restart_teardown_test, &AccountGeneration.process_stopped/1, :invalidated, :continuity_lost}

    for {name, transition, expected_change, expected_reason} <- [
          {:account_generation_restart_logout_test,
           fn session ->
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => nil}})
           end, :invalidated, :logout},
          {:account_generation_restart_refresh_test,
           fn session ->
             AccountGeneration.handle_notification(session, "account/chatgptAuthTokens/refresh", %{"params" => %{}})
           end, nil, :never_observed},
          {:account_generation_restart_unsupported_test,
           fn session ->
             AccountGeneration.handle_notification(session, "account/updated", %{
               "params" => %{"authMode" => "unknown-mode"}
             })
           end, :invalidated, :unsupported_auth_mode},
          teardown_transition
        ] do
      {replacement_owner, session} = restarted_session(name)

      assert_transition_result(transition.(session))

      assert_receive {:provider_account_generation_changed, recovered}, 2_000
      assert %{change: :recovered, generation: nil, reason: :never_observed} = recovered

      if expected_change do
        assert_receive {:provider_account_generation_changed, changed}, 2_000
        assert %{change: ^expected_change, generation: nil, reason: ^expected_reason} = changed
      else
        refute_receive {:provider_account_generation_changed, _event}, 100
      end

      assert %{generation: nil, reason: ^expected_reason} =
               ProviderAccountGeneration.lookup(
                 replacement_owner,
                 :codex,
                 :app_server,
                 session.account_generation_binding
               )
    end
  end

  test "an outage-created session retains an opaque topic that a later owner can recover" do
    name = :account_generation_outage_binding_test
    account_generation = AccountGeneration.new_binding(name)

    on_exit(fn -> stop_named_owner(name) end)

    session = %{
      account_generation_binding: account_generation.binding,
      account_generation_authority: account_generation.authority,
      account_generation_context: account_generation.context,
      account_generation_topic: account_generation.topic,
      account_generation_server: name
    }

    assert is_binary(account_generation.topic)
    {:ok, owner} = ProviderAccountGeneration.start_link(name: name, mint: sequence_mint())

    assert {:error, :owner_unavailable} =
             ProviderAccountGeneration.subscribe(owner, :codex, :app_server, session.account_generation_binding)

    parent = self()

    spawn(fn ->
      result =
        AccountGeneration.handle_notification(session, "account/updated", %{
          "params" => %{"authMode" => "chatgpt"}
        })

      send(parent, {:copied_outage_session, result})
    end)

    assert_receive {:copied_outage_session, {:redacted, _}}, 2_000

    assert %{generation: nil, reason: :never_observed} =
             ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{
               "params" => %{"authMode" => "chatgpt"}
             })

    assert %{generation: first_generation} =
             ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    assert is_binary(first_generation)
    assert :ok = ProviderAccountGeneration.subscribe(owner, :codex, :app_server, session.account_generation_binding)

    assert {:redacted, _} = AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    assert_receive {:provider_account_generation_changed, %{change: :rotated, generation: replacement_generation}},
                   2_000

    refute replacement_generation == first_generation
  end

  test "state-machine property: lifecycle sequences never retain a stale known generation" do
    owner = start_owner(mint: sequence_mint(), clock: fn -> ~U[2026-07-13 12:00:00Z] end)

    events = [:account_chatgpt, :stale_chatgpt, :refresh, :logout, :unsupported, :teardown]

    for sequence <- lifecycle_sequences(events, 3) do
      account_generation = AccountGeneration.new_binding(owner)

      session = %{
        account_generation_binding: account_generation.binding,
        account_generation_authority: account_generation.authority,
        account_generation_context: account_generation.context,
        account_generation_topic: account_generation.topic,
        account_generation_server: owner
      }

      Enum.reduce(sequence, nil, fn event, previous ->
        assert_transition_result(apply_lifecycle_event(session, event))

        snapshot = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)
        assert is_nil(snapshot.generation) or is_binary(snapshot.generation)

        case {event, previous} do
          {:refresh, previous} when is_map(previous) ->
            assert snapshot == previous

          {event, %{generation: generation}}
          when event in [:account_chatgpt, :stale_chatgpt] and is_binary(generation) ->
            refute snapshot.generation == generation

          _ ->
            :ok
        end

        snapshot
      end)
    end
  end

  test "teardown preserves explicit logout and unsupported-auth reasons", %{owner: owner, session: session} do
    for {payload, reason} <- [
          {%{"params" => %{"authMode" => nil}}, :logout},
          {%{"params" => %{"authMode" => "unknown-mode"}}, :unsupported_auth_mode}
        ] do
      account_generation = AccountGeneration.new_binding(owner)

      lifecycle_session = %{
        session
        | account_generation_binding: account_generation.binding,
          account_generation_authority: account_generation.authority,
          account_generation_context: account_generation.context,
          account_generation_topic: account_generation.topic
      }

      assert {:redacted, _} = AccountGeneration.handle_notification(lifecycle_session, "account/updated", payload)
      assert :ok = AccountGeneration.process_stopped(lifecycle_session)

      assert %{generation: nil, reason: ^reason} =
               ProviderAccountGeneration.lookup(
                 owner,
                 :codex,
                 :app_server,
                 lifecycle_session.account_generation_binding
               )
    end
  end

  defp restarted_session(name) do
    mint = sequence_mint()
    {:ok, owner} = ProviderAccountGeneration.start_link(name: name, mint: mint)

    on_exit(fn -> stop_named_owner(name) end)

    account_generation = AccountGeneration.new_binding(name)

    session = %{
      account_generation_binding: account_generation.binding,
      account_generation_authority: account_generation.authority,
      account_generation_context: account_generation.context,
      account_generation_topic: account_generation.topic,
      account_generation_server: name
    }

    assert :ok = ProviderAccountGeneration.subscribe(owner, :codex, :app_server, session.account_generation_binding)

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{
               "params" => %{"authMode" => "chatgpt"}
             })

    assert_receive {:provider_account_generation_changed, %{change: :bound}}, 2_000
    GenServer.stop(owner)
    {:ok, replacement_owner} = ProviderAccountGeneration.start_link(name: name, mint: mint)
    {replacement_owner, session}
  end

  defp apply_lifecycle_event(session, :account_chatgpt),
    do: AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

  defp apply_lifecycle_event(session, :stale_chatgpt),
    do: AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

  defp apply_lifecycle_event(session, :refresh),
    do: AccountGeneration.handle_notification(session, "account/chatgptAuthTokens/refresh", %{"params" => %{}})

  defp apply_lifecycle_event(session, :logout),
    do: AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => nil}})

  defp apply_lifecycle_event(session, :unsupported) do
    AccountGeneration.handle_notification(session, "account/updated", %{
      "params" => %{"authMode" => "unknown-mode"}
    })
  end

  defp apply_lifecycle_event(session, :teardown), do: AccountGeneration.process_stopped(session)

  defp lifecycle_sequences(events, depth) do
    Enum.flat_map(0..depth, fn length -> lifecycle_sequences_of_length(events, length) end)
  end

  defp lifecycle_sequences_of_length(_events, 0), do: [[]]

  defp lifecycle_sequences_of_length(events, length) do
    for event <- events,
        suffix <- lifecycle_sequences_of_length(events, length - 1),
        do: [event | suffix]
  end

  defp assert_transition_result(:ok), do: :ok
  defp assert_transition_result({:redacted, _details}), do: :ok

  defp stop_named_owner(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> GenServer.stop(pid)
      _ -> :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
