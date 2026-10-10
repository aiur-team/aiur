defmodule Aiur.ProviderAccountGenerationTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport.ProviderAccountGeneration

  alias Aiur.ProviderAccountGeneration

  @clock ~U[2026-07-13 12:00:00Z]

  setup_all do
    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub}, id: {Phoenix.PubSub, Aiur.PubSub})
    end

    :ok
  end

  setup do
    owner = start_owner(mint: sequence_mint(self()), clock: fn -> @clock end)
    %{owner: owner}
  end

  test "starts unknown and mints one opaque generation for a trusted binding", %{owner: owner} do
    binding = issued_binding(owner)

    assert unknown = ProviderAccountGeneration.lookup(owner, :codex, :app_server, binding)
    assert unknown.generation == nil
    assert unknown.source == :unavailable
    assert unknown.freshness == :unknown
    assert unknown.health == :unavailable
    assert unknown.reason == :never_observed

    assert {:ok, bound} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding, source: :codex_app_server, auth_mode: "chatgpt")

    assert bound.schema_version == 1
    assert bound.provider == :codex
    assert bound.backend == :app_server
    assert bound.generation == "generation-1"
    assert bound.source == :codex_app_server
    assert bound.freshness == :current
    assert bound.health == :healthy
    assert bound.observed_at == @clock
    assert_received :minted

    assert {:ok, repeated_bind} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding,
               source: :codex_app_server,
               auth_mode: "chatgpt",
               continuity: :proven
             )

    assert repeated_bind == bound

    assert {:ok, repeated} =
             ProviderAccountGeneration.confirm(owner, :codex, :app_server, binding, source: :codex_app_server)

    assert repeated == bound
    refute_received :minted
  end

  test "trusted Codex and Claude lifecycle owners mint isolated generations", %{owner: owner} do
    codex_binding = issued_binding(owner, :codex)
    claude_binding = issued_binding(owner, :claude)

    assert {:ok, codex} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, codex_binding, source: :codex_app_server)

    assert {:ok, claude} =
             ProviderAccountGeneration.bind(owner, :claude, :app_server, claude_binding,
               source: :claude_app_server,
               auth_mode: "subscription"
             )

    assert is_binary(codex.generation)
    assert is_binary(claude.generation)
    assert claude.generation != codex.generation
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, claude_binding).generation == nil
    assert ProviderAccountGeneration.lookup(owner, :claude, :app_server, codex_binding).generation == nil
  end

  test "two consumer fixtures share a generation and cannot join across an account rotation", %{owner: owner} do
    binding = issued_binding(owner)

    assert {:ok, old} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding, source: :codex_app_server)

    assert usage_generation(owner, binding) == old.generation
    assert meter_generation(owner, binding) == old.generation

    assert {:ok, current} =
             ProviderAccountGeneration.replace(owner, :codex, :app_server, binding, source: :codex_app_server)

    assert current.generation != old.generation
    assert usage_generation(owner, binding) == current.generation
    assert meter_generation(owner, binding) == current.generation
    refute old.generation == meter_generation(owner, binding)
  end

  test "only explicit trusted continuity retains one generation across repeated auth observations", %{owner: owner} do
    first_binding = issued_binding(owner)
    replacement_binding = issued_binding(owner)

    assert {:ok, first} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, first_binding,
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )

    assert {:ok, duplicate} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, first_binding,
               source: :codex_app_server,
               auth_mode: "chatgpt",
               continuity: :proven
             )

    assert duplicate == first

    assert {:ok, continued} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, replacement_binding,
               source: :codex_app_server,
               auth_mode: "chatgpt",
               continuity: :proven,
               previous_binding: first_binding
             )

    assert continued.generation == first.generation
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, first_binding).reason == :continuity_lost

    assert {:ok, %{generation: nil, reason: :owner_unavailable}} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, first_binding,
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )

    assert {:error, :owner_unavailable} =
             ProviderAccountGeneration.recover_binding(owner, :codex, :app_server, first_binding)
  end

  test "a mode change rotates one binding only after trusted evidence changes", %{owner: owner} do
    binding = issued_binding(owner)

    assert {:ok, first} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding,
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )

    assert {:ok, replacement} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding,
               source: :codex_app_server,
               auth_mode: "apikey"
             )

    refute replacement.generation == first.generation
  end

  test "same-mode evidence rotates unless the trusted owner proves continuity", %{owner: owner} do
    binding = issued_binding(owner)

    assert {:ok, first} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding,
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )

    assert {:ok, replacement} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding,
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )

    refute replacement.generation == first.generation

    assert {:ok, continued} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding,
               source: :codex_app_server,
               auth_mode: "chatgpt",
               continuity: :proven
             )

    assert continued == replacement
  end

  test "a consumer with only a lookup binding cannot mutate a trusted lifecycle generation", %{owner: owner} do
    binding = issued_binding(owner)

    assert {:ok, original} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding,
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )

    parent = self()

    spawn(fn ->
      result =
        ProviderAccountGeneration.replace(owner, :codex, :app_server, binding.binding,
          source: :codex_app_server,
          auth_mode: "apikey"
        )

      send(parent, {:consumer_replace, result})
    end)

    assert_receive {:consumer_replace, {:ok, %{generation: nil, reason: :owner_unavailable}}}, 2_000
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, binding) == original
  end

  test "recovery cannot replace the authority for a live binding", %{owner: owner} do
    binding = issued_binding(owner)

    assert {:error, :owner_unavailable} =
             ProviderAccountGeneration.recover_binding(owner, :codex, :app_server, %{
               binding: binding.binding,
               authority: make_ref(),
               topic: binding.topic
             })

    assert {:ok, %{generation: generation}} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding,
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )

    assert is_binary(generation)
  end

  test "a caller-supplied source cannot mint an unissued binding", %{owner: owner} do
    assert {:ok, %{generation: nil, reason: :owner_unavailable}} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, make_ref(),
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )
  end

  test "a replacement cannot consume another binding without its authority", %{owner: owner} do
    victim = issued_binding(owner)
    replacement = issued_binding(owner)

    assert {:ok, original} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, victim,
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )

    assert {:ok, %{generation: nil, reason: :owner_unavailable}} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, replacement,
               source: :codex_app_server,
               continuity: :proven,
               previous_binding: victim.binding
             )

    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, victim) == original
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, replacement).generation == nil
  end

  test "unproven replacement invalidates its old binding before exposing the new one", %{owner: owner} do
    old_binding = issued_binding(owner)
    new_binding = issued_binding(owner)

    assert :ok = ProviderAccountGeneration.subscribe(owner, :codex, :app_server, old_binding)

    assert {:ok, old} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, old_binding, source: :codex_app_server)

    assert_receive {:provider_account_generation_changed, %{change: :bound, generation: generation}}, 2_000
    assert generation == old.generation

    assert {:ok, replacement} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, new_binding,
               source: :codex_app_server,
               previous_binding: old_binding
             )

    assert replacement.generation != old.generation
    assert_receive {:provider_account_generation_changed, invalidated}, 2_000
    assert %{change: :invalidated, reason: :continuity_lost, generation: nil} = invalidated
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, old_binding).reason == :continuity_lost
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, new_binding) == replacement

    assert {:ok, %{generation: nil, reason: :owner_unavailable}} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, old_binding, source: :codex_app_server)
  end

  test "invalidation preserves the known reason for later lookup", %{owner: owner} do
    for reason <- [:logout, :credential_replaced, :continuity_lost] do
      binding = issued_binding(owner)

      assert {:ok, _bound} =
               ProviderAccountGeneration.bind(owner, :codex, :app_server, binding, source: :codex_app_server)

      assert {:ok, %{generation: nil, reason: ^reason}} =
               ProviderAccountGeneration.invalidate(owner, :codex, :app_server, binding,
                 source: :codex_app_server,
                 reason: reason
               )

      assert %{generation: nil, reason: ^reason} = ProviderAccountGeneration.lookup(owner, :codex, :app_server, binding)
    end
  end

  test "retiring final bindings prevents resurrection and bounds retained tombstones" do
    name = :provider_account_generation_tombstone_recovery_test

    {:ok, owner} =
      ProviderAccountGeneration.start_link(
        name: name,
        mint: sequence_mint(self()),
        tombstone_limit: 2,
        clock: fn -> @clock end
      )

    on_exit(fn -> stop_named_owner(name) end)

    bindings =
      Enum.map(1..3, fn _index ->
        binding = issued_binding(owner)

        assert {:ok, %{generation: generation}} =
                 ProviderAccountGeneration.bind(owner, :codex, :app_server, binding,
                   source: :codex_app_server,
                   auth_mode: "chatgpt"
                 )

        assert is_binary(generation)

        assert {:ok, %{generation: nil, reason: :continuity_lost}} =
                 ProviderAccountGeneration.retire(owner, :codex, :app_server, binding,
                   source: :codex_app_server,
                   reason: :continuity_lost
                 )

        assert {:error, :owner_unavailable} =
                 ProviderAccountGeneration.recover_binding(owner, :codex, :app_server, binding)

        binding
      end)

    [oldest | _recent] = bindings

    assert %{entries: entries, tombstones: tombstones, tombstone_order: tombstone_order} = :sys.get_state(owner)

    assert entries == %{}
    assert map_size(tombstones) == 2
    assert length(tombstone_order) == 2
    refute Map.has_key?(tombstones, {:codex, :app_server, oldest.binding})

    GenServer.stop(owner)

    {:ok, replacement_owner} =
      ProviderAccountGeneration.start_link(
        name: name,
        mint: sequence_mint(self()),
        tombstone_limit: 2,
        clock: fn -> @clock end
      )

    assert {:error, :owner_unavailable} =
             ProviderAccountGeneration.recover_binding(replacement_owner, :codex, :app_server, oldest)

    assert {:ok, %{generation: nil, reason: :owner_unavailable}} =
             ProviderAccountGeneration.bind(replacement_owner, :codex, :app_server, oldest,
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )
  end

  defp usage_generation(owner, binding) do
    ProviderAccountGeneration.lookup(owner, :codex, :app_server, binding).generation
  end

  defp meter_generation(owner, binding) do
    ProviderAccountGeneration.lookup(owner, :codex, :app_server, binding).generation
  end
end
