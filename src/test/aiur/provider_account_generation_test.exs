defmodule Aiur.ProviderAccountGenerationTest do
  use ExUnit.Case, async: true

  alias Aiur.ProviderAccountGeneration

  @clock ~U[2026-07-13 12:00:00Z]

  setup do
    owner = start_owner(mint: sequence_mint(self()), clock: fn -> @clock end)

    %{owner: owner}
  end

  test "starts unknown and mints one opaque generation for a trusted binding", %{owner: owner} do
    binding = make_ref()

    assert unknown = ProviderAccountGeneration.lookup(owner, :codex, :app_server, binding)
    assert unknown.generation == nil
    assert unknown.source == :unavailable
    assert unknown.freshness == :unknown
    assert unknown.health == :unavailable
    assert unknown.reason == :no_trusted_binding

    assert {:ok, bound} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding, source: :codex_app_server)

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
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding, source: :codex_app_server)

    assert repeated_bind == bound

    assert {:ok, repeated} =
             ProviderAccountGeneration.confirm(owner, :codex, :app_server, binding, source: :codex_app_server)

    assert repeated == bound
    refute_received :minted
  end

  test "isolates provider and backend bindings", %{owner: owner} do
    codex_binding = make_ref()
    claude_binding = make_ref()

    assert {:ok, codex} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, codex_binding, source: :codex_app_server)

    assert {:ok, claude} =
             ProviderAccountGeneration.bind(owner, :claude, :app_server, claude_binding, source: :claude_app_server)

    assert codex.generation != claude.generation
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, claude_binding).generation == nil
    assert ProviderAccountGeneration.lookup(owner, :claude, :app_server, codex_binding).generation == nil
  end

  test "two consumer fixtures share a generation and cannot join across an account rotation", %{owner: owner} do
    binding = make_ref()

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

  test "preserves a generation only for an explicit proven process replacement", %{owner: owner} do
    first_binding = make_ref()
    proven_replacement = make_ref()
    unproven_replacement = make_ref()

    assert {:ok, first} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, first_binding, source: :codex_app_server)

    assert {:ok, continued} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, proven_replacement,
               source: :codex_app_server,
               continuity: :proven,
               previous_binding: first_binding
             )

    assert continued.generation == first.generation
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, first_binding).generation == nil

    assert {:ok, rotated} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, unproven_replacement, source: :codex_app_server)

    assert rotated.generation != first.generation
  end

  test "logout and continuity loss make the active binding explicitly unknown", %{owner: owner} do
    binding = make_ref()

    assert {:ok, _bound} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding, source: :codex_app_server)

    assert {:ok, logged_out} =
             ProviderAccountGeneration.invalidate(owner, :codex, :app_server, binding,
               source: :codex_app_server,
               reason: :logout
             )

    assert logged_out.generation == nil
    assert logged_out.health == :unknown
    assert logged_out.reason == :logout

    assert {:ok, lost} =
             ProviderAccountGeneration.invalidate(owner, :codex, :app_server, binding,
               source: :codex_app_server,
               reason: :continuity_lost
             )

    assert lost.generation == nil
    assert lost.reason == :continuity_lost
  end

  test "an explicit account replacement rotates the active binding", %{owner: owner} do
    binding = make_ref()

    assert {:ok, first} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding, source: :codex_app_server)

    assert {:ok, replacement} =
             ProviderAccountGeneration.replace(owner, :codex, :app_server, binding, source: :codex_app_server)

    assert replacement.generation != first.generation
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, binding) == replacement
  end

  test "credential replacement invalidates the active binding", %{owner: owner} do
    binding = make_ref()

    assert {:ok, _bound} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding, source: :codex_app_server)

    assert {:ok, unknown} =
             ProviderAccountGeneration.invalidate(owner, :codex, :app_server, binding,
               source: :codex_app_server,
               reason: :credential_replaced
             )

    assert unknown.generation == nil
    assert unknown.reason == :credential_replaced
  end

  test "stale invalidation cannot disturb a newer binding", %{owner: owner} do
    old_binding = make_ref()
    new_binding = make_ref()

    assert {:ok, _old} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, old_binding, source: :codex_app_server)

    assert {:ok, current} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, new_binding, source: :codex_app_server)

    assert {:ok, stale} =
             ProviderAccountGeneration.invalidate(owner, :codex, :app_server, old_binding,
               source: :codex_app_server,
               reason: :logout
             )

    assert stale.generation == nil
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, new_binding) == current
  end

  test "concurrent process bindings remain isolated when one loses continuity", %{owner: owner} do
    first_binding = make_ref()
    second_binding = make_ref()

    assert {:ok, first} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, first_binding, source: :codex_app_server)

    assert {:ok, second} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, second_binding, source: :codex_app_server)

    refute first.generation == second.generation

    assert {:ok, unknown} =
             ProviderAccountGeneration.invalidate(owner, :codex, :app_server, first_binding,
               source: :codex_app_server,
               reason: :continuity_lost
             )

    assert unknown.generation == nil
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, second_binding) == second
  end

  test "Claude is explicitly unknown until a trusted Claude lifecycle owner binds it", %{owner: owner} do
    snapshot = ProviderAccountGeneration.lookup(owner, :claude, :app_server, make_ref())

    assert snapshot.generation == nil
    assert snapshot.source == :unavailable
    assert snapshot.reason == :no_trusted_binding
  end

  test "publishes a versioned redacted change event", %{owner: owner} do
    binding = make_ref()
    raw_identity = "person@example.test credential=super-secret"

    assert :ok = ProviderAccountGeneration.subscribe(:codex, :app_server)

    assert {:ok, bound} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding, source: :codex_app_server)

    assert_receive {:provider_account_generation_changed, event}
    assert event.schema_version == 1
    assert event.change == :bound
    assert event.generation == bound.generation
    assert event.provider == :codex
    refute inspect(event) =~ raw_identity
    refute inspect(:sys.get_state(owner)) =~ raw_identity
  end

  test "rejects untrusted sources and invalid bindings", %{owner: owner} do
    assert {:error, :invalid_observation} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, "not-a-local-binding", source: :browser)

    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, make_ref()).generation == nil
  end

  test "default minting is non-derivable and distinct" do
    owner = start_owner(clock: fn -> @clock end)

    assert {:ok, first} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, make_ref(), source: :codex_app_server)

    assert {:ok, second} =
             ProviderAccountGeneration.bind(owner, :claude, :app_server, make_ref(), source: :claude_app_server)

    assert first.generation != second.generation
    assert String.match?(first.generation, ~r/^[A-Za-z0-9_-]{43}$/)
    refute first.generation =~ "codex"
    refute first.generation =~ "app_server"
  end

  defp usage_generation(owner, binding) do
    ProviderAccountGeneration.lookup(owner, :codex, :app_server, binding).generation
  end

  defp meter_generation(owner, binding) do
    ProviderAccountGeneration.lookup(owner, :codex, :app_server, binding).generation
  end

  defp start_owner(opts) do
    {:ok, owner} = ProviderAccountGeneration.start_link(Keyword.put(opts, :name, nil))
    owner
  end

  defp sequence_mint(test_pid) do
    counter = :counters.new(1, [])

    fn ->
      :counters.add(counter, 1, 1)
      value = :counters.get(counter, 1)
      send(test_pid, :minted)
      "generation-#{value}"
    end
  end
end
