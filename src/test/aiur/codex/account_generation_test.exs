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

  test "duplicate and out-of-order account updates are stable, while a trusted mode change rotates", %{owner: owner, session: session} do
    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    first = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    repeated = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)
    assert repeated == first

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "apikey"}})

    current = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)
    refute current.generation == first.generation
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

  test "trusted authenticated evidence re-registers a live session after its owner restarts" do
    name = :provider_account_generation_restart_test
    {:ok, owner} = ProviderAccountGeneration.start_link(name: name, mint: sequence_mint())

    on_exit(fn ->
      if Process.whereis(name), do: GenServer.stop(name)
    end)

    account_generation = AccountGeneration.new_binding(name)

    session = %{
      account_generation_binding: account_generation.binding,
      account_generation_authority: account_generation.authority,
      account_generation_context: account_generation.context,
      account_generation_server: name
    }

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    GenServer.stop(owner)
    {:ok, replacement_owner} = ProviderAccountGeneration.start_link(name: name, mint: sequence_mint())

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    assert Enum.any?(:sys.get_state(replacement_owner).entries, fn {_key, entry} ->
             is_binary(entry.snapshot.generation)
           end)
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
end
