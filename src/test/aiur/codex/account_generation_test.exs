defmodule Aiur.Codex.AccountGenerationTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.AccountGeneration
  alias Aiur.ProviderAccountGeneration

  setup do
    owner = start_owner(mint: sequence_mint(), clock: fn -> ~U[2026-07-13 12:00:00Z] end)

    session = %{account_generation_binding: AccountGeneration.new_binding(), account_generation_server: owner}
    %{owner: owner, session: session}
  end

  test "account updates create a shared generation and emit only a redacted audit message", %{owner: owner, session: session} do
    raw_identity = "person@example.test credential=super-secret"

    payload = %{
      "method" => "account/updated",
      "params" => %{"authMode" => "chatgpt", "email" => raw_identity, "credential" => raw_identity}
    }

    assert {:redacted, details} = AccountGeneration.handle_notification(session, "account/updated", payload)
    assert details == %{payload: %{"method" => "account/updated", "params" => %{}}, raw: nil}

    assert snapshot =
             ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    assert is_binary(snapshot.generation)
    refute inspect(details) =~ raw_identity
    refute inspect(:sys.get_state(owner)) =~ raw_identity
  end

  test "token refresh confirms rather than rotates a known binding", %{owner: owner, session: session} do
    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    first = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    assert {:redacted, %{} = details} =
             AccountGeneration.handle_notification(session, "account/chatgptAuthTokens/refresh", %{"params" => %{}})

    assert details.raw == nil
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding) == first
  end

  test "quota updates are not account lifecycle evidence", %{owner: owner, session: session} do
    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    first = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    assert :ignore =
             AccountGeneration.handle_notification(session, "account/rateLimits/updated", %{
               "params" => %{"rateLimits" => %{"primary" => %{"usedPercent" => 100}}}
             })

    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding) == first
  end

  test "a later trusted account update rotates the active binding", %{owner: owner, session: session} do
    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    first = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    current = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)
    refute current.generation == first.generation
  end

  test "malformed account evidence invalidates a known binding", %{owner: owner, session: session} do
    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    assert {:redacted, _} = AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{}})

    snapshot = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)
    assert snapshot.generation == nil
    assert snapshot.reason == :no_trusted_binding
  end

  test "process teardown loses continuity and unrelated notifications are ignored", %{owner: owner, session: session} do
    assert :ignore = AccountGeneration.handle_notification(session, "thread/status/changed", %{"params" => %{}})

    assert {:redacted, _} =
             AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

    assert :ok = AccountGeneration.process_stopped(session)

    snapshot = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)
    assert snapshot.generation == nil
    assert snapshot.reason == :no_trusted_binding
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
