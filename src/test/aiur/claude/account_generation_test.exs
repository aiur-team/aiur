defmodule Aiur.Claude.AccountGenerationTest do
  use ExUnit.Case, async: false

  alias Aiur.Claude.{AccountGeneration, MeterTestSupport}
  alias Aiur.ProviderAccountGeneration

  setup do
    MeterTestSupport.ensure_pubsub()
    {:ok, owner} = ProviderAccountGeneration.start_link(name: nil, mint: MeterTestSupport.sequence_mint())
    session = MeterTestSupport.generation_session(owner)
    %{owner: owner, session: session, binding: session.account_generation_binding}
  end

  test "auth observations rotate only when the trusted account mode changes", %{
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

  test "same-mode observations recover after the account-generation owner restarts" do
    name = __MODULE__.RestartOwner
    mint = MeterTestSupport.sequence_mint()
    on_exit(fn -> Aiur.TestSupport.safe_stop(name) end)

    {:ok, first_owner} = ProviderAccountGeneration.start_link(name: name, mint: mint)
    session = MeterTestSupport.generation_session(name)

    assert {:ok, binding} = AccountGeneration.observe(session, :subscription)
    first_generation = ProviderAccountGeneration.lookup(name, :claude, :app_server, binding).generation
    assert is_binary(first_generation)

    GenServer.stop(first_owner)
    {:ok, _second_owner} = ProviderAccountGeneration.start_link(name: name, mint: mint)

    assert {:ok, ^binding} = AccountGeneration.observe(session, :subscription)
    recovered_generation = ProviderAccountGeneration.lookup(name, :claude, :app_server, binding).generation
    assert is_binary(recovered_generation)
    assert recovered_generation != first_generation

    assert :ok = AccountGeneration.process_stopped(session)
  end
end
