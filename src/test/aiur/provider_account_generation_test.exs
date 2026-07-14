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
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding, source: :codex_app_server, auth_mode: "chatgpt")

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

  test "stable duplicate auth observations retain one generation and a proven replacement carries it", %{owner: owner} do
    first_binding = make_ref()
    replacement_binding = make_ref()

    assert {:ok, first} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, first_binding,
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )

    assert {:ok, duplicate} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, first_binding,
               source: :codex_app_server,
               auth_mode: "chatgpt"
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
  end

  test "a mode change rotates one binding only after trusted evidence changes", %{owner: owner} do
    binding = make_ref()

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

  test "unproven replacement invalidates its old binding before exposing the new one", %{owner: owner} do
    old_binding = make_ref()
    new_binding = make_ref()

    assert :ok = ProviderAccountGeneration.subscribe(owner, :codex, :app_server, old_binding)

    assert {:ok, old} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, old_binding, source: :codex_app_server)

    assert_receive {:provider_account_generation_changed, %{change: :bound, generation: generation}}
    assert generation == old.generation

    assert {:ok, replacement} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, new_binding,
               source: :codex_app_server,
               previous_binding: old_binding
             )

    assert replacement.generation != old.generation
    assert_receive {:provider_account_generation_changed, %{change: :invalidated, reason: :continuity_lost, generation: nil}}
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, old_binding).reason == :continuity_lost
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, new_binding) == replacement
  end

  test "invalidation preserves the known reason for later lookup", %{owner: owner} do
    for reason <- [:logout, :credential_replaced, :continuity_lost] do
      binding = make_ref()

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

  test "subscription topics are exact-binding capabilities", %{owner: owner} do
    first_binding = make_ref()
    second_binding = make_ref()

    assert :ok = ProviderAccountGeneration.subscribe(owner, :codex, :app_server, first_binding)

    assert {:ok, first} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, first_binding, source: :codex_app_server)

    assert_receive {:provider_account_generation_changed, %{generation: generation}}
    assert generation == first.generation

    assert {:ok, _second} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, second_binding, source: :codex_app_server)

    refute_receive {:provider_account_generation_changed, _event}
  end

  test "an owning process dying invalidates and publishes its former binding", %{owner: owner} do
    binding = make_ref()
    parent = self()

    assert :ok = ProviderAccountGeneration.subscribe(owner, :codex, :app_server, binding)

    owner_process =
      spawn(fn ->
        {:ok, snapshot} =
          ProviderAccountGeneration.bind(owner, :codex, :app_server, binding, source: :codex_app_server)

        send(parent, {:bound_from_owner, snapshot})
        Process.sleep(:infinity)
      end)

    assert_receive {:bound_from_owner, snapshot}
    assert_receive {:provider_account_generation_changed, %{change: :bound}}
    Process.exit(owner_process, :kill)

    assert_receive {:provider_account_generation_changed, %{change: :invalidated, reason: :continuity_lost, generation: nil}}
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, binding).generation == nil
    refute snapshot.generation == ProviderAccountGeneration.lookup(owner, :codex, :app_server, binding).generation
  end

  test "owner outages fail open as an explicit unknown snapshot", %{owner: owner} do
    GenServer.stop(owner)

    assert {:ok, unknown} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, make_ref(), source: :codex_app_server)

    assert unknown.generation == nil
    assert unknown.health == :unavailable
    assert unknown.reason == :owner_unavailable
  end

  test "events and owner state retain no identity payload", %{owner: owner} do
    binding = make_ref()
    raw_identity = "person@example.test credential=super-secret"

    assert :ok = ProviderAccountGeneration.subscribe(owner, :codex, :app_server, binding)

    assert {:ok, bound} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding, source: :codex_app_server)

    assert_receive {:provider_account_generation_changed, event}
    assert event.schema_version == 1
    assert event.generation == bound.generation
    refute inspect(event) =~ raw_identity
    refute inspect(:sys.get_state(owner)) =~ raw_identity
  end

  test "rejects untrusted sources, invalid bindings, and unsupported auth modes", %{owner: owner} do
    assert {:ok, %{reason: :owner_unavailable}} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, "not-a-local-binding", source: :browser)

    assert {:ok, %{reason: :owner_unavailable}} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, make_ref(),
               source: :codex_app_server,
               auth_mode: "made-up"
             )
  end

  test "accepts only the finite trusted auth-mode vocabulary", %{owner: owner} do
    for auth_mode <- ~w(apikey chatgpt chatgptAuthTokens headers agentIdentity personalAccessToken bedrockApiKey) do
      assert {:ok, %{generation: generation}} =
               ProviderAccountGeneration.bind(owner, :codex, :app_server, make_ref(),
                 source: :codex_app_server,
                 auth_mode: auth_mode
               )

      assert is_binary(generation)
    end
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
