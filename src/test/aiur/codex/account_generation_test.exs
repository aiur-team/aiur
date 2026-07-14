defmodule Aiur.Codex.AccountGenerationTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.AccountGeneration
  alias Aiur.ProviderAccountGeneration

  setup do
    owner = start_owner(mint: sequence_mint(), clock: fn -> ~U[2026-07-13 12:00:00Z] end)
    account_generation = AccountGeneration.new_binding(owner)

    session = %{
      account_generation_binding: account_generation.binding,
      account_generation_authority: account_generation.authority,
      account_generation_context: account_generation.context,
      account_generation_topic: account_generation.topic,
      account_generation_server: owner
    }

    %{owner: owner, session: session}
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
  end

  test "account updates create a shared generation and emit only a redacted audit message", %{owner: owner, session: session} do
    raw_identity = "person@example.test credential=super-secret"

    payload = %{
      "method" => "account/updated",
      "params" => %{"authMode" => "chatgpt", "email" => raw_identity, "credential" => raw_identity}
    }

    assert {:redacted, details} = AccountGeneration.handle_notification(session, "account/updated", payload)
    assert details == %{payload: %{"method" => "account/updated", "params" => %{}}, raw: nil}

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
    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    first = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    assert {:redacted, %{raw: nil}} =
             AccountGeneration.handle_notification(session, "account/chatgptAuthTokens/refresh", %{"params" => %{}})

    assert {:redacted, %{payload: %{"method" => "account/rateLimits/updated", "params" => %{}}, raw: nil}} =
             AccountGeneration.handle_notification(session, "account/rateLimits/updated", %{
               "params" => %{"rateLimits" => %{"primary" => %{"usedPercent" => 100}}}
             })

    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding) == first
  end

  test "unrecognized account notifications invalidate and redact provider payloads", %{owner: owner, session: session} do
    assert :ok =
             AccountGeneration.seed_from_account_read(session, %{auth_mode: "chatgpt"})

    assert {:redacted, details} =
             AccountGeneration.handle_notification(session, "account/futureLifecycle", %{
               "params" => %{"email" => "person@example.test", "credential" => "super-secret"}
             })

    assert details == %{payload: %{"method" => "account/futureLifecycle", "params" => %{}}, raw: nil}

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

  test "trusted authenticated evidence restores the binding retained by session consumers after its owner restarts" do
    name = :provider_account_generation_restart_test
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
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    assert_receive {:provider_account_generation_changed, %{change: :bound, generation: original_generation}}

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

    assert_receive {:provider_account_generation_changed, recovered}
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
    assert_receive {:provider_account_generation_changed, %{change: :bound, generation: ^recovered_generation}}
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

      assert_receive {:provider_account_generation_changed, recovered}
      assert %{change: :recovered, generation: nil, reason: :never_observed} = recovered

      if expected_change do
        assert_receive {:provider_account_generation_changed, changed}
        assert %{change: ^expected_change, generation: nil, reason: ^expected_reason} = changed
      else
        refute_receive {:provider_account_generation_changed, _event}
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

    recovery_pid =
      spawn(fn ->
        result =
          AccountGeneration.handle_notification(session, "account/updated", %{
            "params" => %{"authMode" => "chatgpt"}
          })

        send(parent, {:outage_recovery, result})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:outage_recovery, {:redacted, _}}

    assert %{generation: first_generation} =
             ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    assert is_binary(first_generation)
    assert :ok = ProviderAccountGeneration.subscribe(owner, :codex, :app_server, session.account_generation_binding)

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{
               "params" => %{"authMode" => "chatgpt"}
             })

    assert_receive {:provider_account_generation_changed, %{change: :rotated, generation: replacement_generation}}

    refute replacement_generation == first_generation
    send(recovery_pid, :stop)
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

  defp sequence_mint do
    counter = :counters.new(1, [])

    fn ->
      :counters.add(counter, 1, 1)
      value = :counters.get(counter, 1)
      "generation-#{value}"
    end
  end

  defp start_owner(opts) do
    {:ok, owner} = ProviderAccountGeneration.start_link(Keyword.put(opts, :name, nil))
    owner
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

    assert_receive {:provider_account_generation_changed, %{change: :bound}}
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
