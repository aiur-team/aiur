defmodule Aiur.ProviderAccountGenerationRecoveryTest do
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

  test "subscription topics are exact-binding capabilities", %{owner: owner} do
    first_binding = issued_binding(owner)
    second_binding = issued_binding(owner)

    assert :ok = ProviderAccountGeneration.subscribe(owner, :codex, :app_server, first_binding)

    assert {:ok, first} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, first_binding, source: :codex_app_server)

    assert_receive {:provider_account_generation_changed, %{generation: generation}}, 2_000
    assert generation == first.generation

    assert {:ok, _second} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, second_binding, source: :codex_app_server)

    refute_receive {:provider_account_generation_changed, _event}, 100
  end

  test "subscribers cannot attach to a replacement topic before retained recovery" do
    name = :provider_account_generation_subscription_recovery_test
    mint = sequence_mint(self())
    {:ok, owner} = ProviderAccountGeneration.start_link(name: name, mint: mint)

    on_exit(fn -> stop_named_owner(name) end)

    binding = issued_binding(owner)
    original_topic = binding.topic

    GenServer.stop(owner)
    {:ok, replacement_owner} = ProviderAccountGeneration.start_link(name: name, mint: mint)

    assert {:error, :owner_unavailable} =
             ProviderAccountGeneration.subscribe(replacement_owner, :codex, :app_server, binding.binding)

    assert :ok = ProviderAccountGeneration.recover_binding(replacement_owner, :codex, :app_server, binding)
    assert :ok = ProviderAccountGeneration.subscribe(replacement_owner, :codex, :app_server, binding.binding)

    assert {:ok, %{generation: generation}} =
             ProviderAccountGeneration.bind(replacement_owner, :codex, :app_server, binding,
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )

    assert_receive {:provider_account_generation_changed, %{change: :bound, generation: ^generation}}, 2_000

    binding_ref = binding.binding

    assert %{entries: %{{:codex, :app_server, ^binding_ref} => %{topic: ^original_topic}}} =
             :sys.get_state(replacement_owner)
  end

  test "recovery rejects a caller-invented binding capability", %{owner: owner} do
    invented = %{binding: make_ref(), authority: make_ref(), topic: "provider-account-generation:invented"}

    assert {:error, :owner_unavailable} =
             ProviderAccountGeneration.recover_binding(owner, :codex, :app_server, invented)

    assert {:ok, %{generation: nil, reason: :owner_unavailable}} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, invented,
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )

    assert %{entries: %{}} = :sys.get_state(owner)
  end

  test "recovery requires the exact retained topic" do
    name = :provider_account_generation_exact_topic_recovery_test
    {:ok, owner} = ProviderAccountGeneration.start_link(name: name, mint: sequence_mint(self()))

    on_exit(fn -> stop_named_owner(name) end)

    binding = issued_binding(owner)
    GenServer.stop(owner)
    {:ok, replacement_owner} = ProviderAccountGeneration.start_link(name: name, mint: sequence_mint(self()))

    assert {:error, :owner_unavailable} =
             ProviderAccountGeneration.recover_binding(
               replacement_owner,
               :codex,
               :app_server,
               %{binding | topic: "provider-account-generation:wrong-topic"}
             )

    assert :ok = ProviderAccountGeneration.recover_binding(replacement_owner, :codex, :app_server, binding)
  end

  test "an owner restart rejects a capability after its lifecycle holder exits" do
    name = :provider_account_generation_dead_holder_recovery_test
    {:ok, owner} = ProviderAccountGeneration.start_link(name: name, mint: sequence_mint(self()))

    on_exit(fn -> stop_named_owner(name) end)

    parent = self()

    holder =
      spawn(fn ->
        assert {:ok, binding} = ProviderAccountGeneration.issue_binding(owner, :codex, :app_server)
        send(parent, {:issued_from_holder, binding})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:issued_from_holder, binding}, 2_000
    GenServer.stop(owner)

    monitor = Process.monitor(holder)
    send(holder, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}, 2_000

    {:ok, replacement_owner} = ProviderAccountGeneration.start_link(name: name, mint: sequence_mint(self()))

    assert {:error, :owner_unavailable} =
             ProviderAccountGeneration.recover_binding(replacement_owner, :codex, :app_server, binding)

    assert %{entries: %{}} = :sys.get_state(replacement_owner)
  end

  test "an owning process dying invalidates and publishes its former binding", %{owner: owner} do
    binding = issued_binding(owner)
    parent = self()

    assert :ok = ProviderAccountGeneration.subscribe(owner, :codex, :app_server, binding)

    owner_process =
      spawn(fn ->
        {:ok, snapshot} =
          ProviderAccountGeneration.bind(owner, :codex, :app_server, binding, source: :codex_app_server)

        send(parent, {:bound_from_owner, snapshot})
        Process.sleep(:infinity)
      end)

    assert_receive {:bound_from_owner, snapshot}, 2_000
    assert_receive {:provider_account_generation_changed, %{change: :bound}}, 2_000
    Process.exit(owner_process, :kill)

    assert_receive {:provider_account_generation_changed, invalidated}, 2_000
    assert %{change: :invalidated, reason: :continuity_lost, generation: nil} = invalidated
    assert ProviderAccountGeneration.lookup(owner, :codex, :app_server, binding).generation == nil
    refute snapshot.generation == ProviderAccountGeneration.lookup(owner, :codex, :app_server, binding).generation

    binding_ref = binding.binding

    assert %{entries: entries, tombstones: tombstones} = :sys.get_state(owner)
    assert entries == %{}
    assert %{generation: nil, reason: :continuity_lost} = tombstones[{:codex, :app_server, binding_ref}]
  end

  test "an issued binding retires when its owner dies before the first observation", %{owner: owner} do
    parent = self()

    worker =
      spawn(fn ->
        assert {:ok, binding} = ProviderAccountGeneration.issue_binding(owner, :codex, :app_server)
        send(parent, {:issued_from_worker, binding})
        Process.sleep(:infinity)
      end)

    assert_receive {:issued_from_worker, binding}, 2_000
    monitor = Process.monitor(worker)
    Process.exit(worker, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 2_000

    assert %{entries: entries, tombstones: tombstones} = :sys.get_state(owner)
    assert entries == %{}
    assert %{generation: nil, reason: :never_observed} = tombstones[{:codex, :app_server, binding.binding}]

    assert {:error, :owner_unavailable} =
             ProviderAccountGeneration.recover_binding(owner, :codex, :app_server, binding)
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
    binding = issued_binding(owner)
    raw_identity = "person@example.test credential=super-secret"

    assert :ok = ProviderAccountGeneration.subscribe(owner, :codex, :app_server, binding)

    assert {:ok, bound} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding, source: :codex_app_server)

    assert_receive {:provider_account_generation_changed, event}, 2_000
    assert event.schema_version == 1
    assert event.generation == bound.generation
    refute inspect(event) =~ raw_identity
    refute inspect(:sys.get_state(owner)) =~ raw_identity
  end

  test "rejects untrusted sources, invalid bindings, and unsupported auth modes", %{owner: owner} do
    assert {:ok, %{reason: :owner_unavailable}} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, "not-a-local-binding", source: :browser)

    assert {:ok, %{reason: :owner_unavailable}} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, issued_binding(owner),
               source: :codex_app_server,
               auth_mode: "made-up"
             )
  end

  test "accepts only the finite trusted auth-mode vocabulary", %{owner: owner} do
    for auth_mode <- ~w(apikey chatgpt chatgptAuthTokens headers agentIdentity personalAccessToken bedrockApiKey) do
      assert {:ok, %{generation: generation}} =
               ProviderAccountGeneration.bind(owner, :codex, :app_server, issued_binding(owner),
                 source: :codex_app_server,
                 auth_mode: auth_mode
               )

      assert is_binary(generation)
    end

    for auth_mode <- ~w(subscription api_key) do
      assert {:ok, %{generation: generation}} =
               ProviderAccountGeneration.bind(owner, :claude, :app_server, issued_binding(owner, :claude),
                 source: :claude_app_server,
                 auth_mode: auth_mode
               )

      assert is_binary(generation)
    end

    assert {:ok, %{generation: nil, reason: :owner_unavailable}} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, issued_binding(owner),
               source: :codex_app_server,
               auth_mode: "subscription"
             )

    assert {:ok, %{generation: nil, reason: :owner_unavailable}} =
             ProviderAccountGeneration.bind(owner, :claude, :app_server, issued_binding(owner, :claude),
               source: :claude_app_server,
               auth_mode: "chatgpt"
             )
  end

  test "default minting is non-derivable and distinct" do
    owner = start_owner(clock: fn -> @clock end)

    assert {:ok, first} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, issued_binding(owner), source: :codex_app_server)

    assert {:ok, second} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, issued_binding(owner), source: :codex_app_server)

    assert first.generation != second.generation
    assert String.match?(first.generation, ~r/^[A-Za-z0-9_-]{43}$/)
    refute first.generation =~ "codex"
    refute first.generation =~ "app_server"
  end
end
