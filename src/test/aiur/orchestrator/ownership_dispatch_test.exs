defmodule Aiur.Orchestrator.OwnershipDispatchTest do
  use Aiur.DispatcherTestSupport

  alias Aiur.Orchestrator.{Dispatcher, State}

  @g String.duplicate("a", 26)
  @other String.duplicate("b", 26)

  defp own_issue(id, extra \\ []) do
    struct!(
      Aiur.Issue,
      Keyword.merge(
        [
          id: id,
          identifier: String.replace_prefix(id, "pr-", ""),
          tracker_identity: %Aiur.TrackerIdentity{
            status: :joinable,
            kind: :github,
            owner: "Acme",
            repository: "Widgets",
            provider_id: "n-#{id}",
            identifier: id,
            reason: nil
          },
          state: "todo",
          selected_backend: "codex"
        ],
        extra
      )
    )
  end

  defp record(ticket, gid, key, state \\ "owned") do
    %{state: state, gateway_id: gid, daemon_key: key, ticket: ticket, epoch: 1}
  end

  # Atomic stub: claim succeeds only when the key is absent/released.
  defp stub do
    store = start_supervised!({Agent, fn -> %{} end}, id: make_ref())

    read = fn _repo, key, _ ->
      {:ok, %{oid: nil, record: Agent.get(store, &Map.get(&1, key))}}
    end

    claim = fn _repo, key, claimant, _ ->
      Agent.get_and_update(store, &stub_claim(&1, key, claimant))
    end

    {store, read, claim}
  end

  defp stub_claim(m, key, claimant) do
    case Map.get(m, key) do
      %{state: "owned"} = r ->
        {{:lost, r}, m}

      _ ->
        r = record(key, claimant.gateway_id, claimant.daemon_key)
        {{:won, r}, Map.put(m, key, r)}
    end
  end

  defp run(issue, self, read, claim, extra \\ []) do
    parent = self()

    Dispatcher.do_dispatch_issue(
      %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
      issue,
      nil,
      nil,
      extra ++
        [
          ownership_enabled: true,
          ownership_self: self,
          ownership_read_fun: read,
          ownership_claim_fun: claim,
          lease_claim_fun: fn _ -> :disabled end,
          runner: fn i, _, _ ->
            send(parent, {:started, i.id})
            :ok
          end
        ] ++ extra
    )
  end

  defp me(key \\ "a"), do: %{gateway_id: @g, gateway_label: "pc", daemon_key: key}

  test "two orchestrators racing one todo ticket start exactly one agent" do
    {store, read, claim} = stub()
    i = own_issue("42")

    states =
      for key <- ["a", "b"] do
        Task.async(fn -> run(i, me(key), read, claim) end)
      end
      |> Enum.map(&Task.await(&1, 2_000))

    assert Enum.count(states, &MapSet.member?(&1.claimed, "42")) == 1
    assert Agent.get(store, &map_size/1) == 1
  end

  test "same gateway_id, different daemon_key: only the claimant dispatches" do
    {_store, read, claim} = stub()
    i = own_issue("43")
    a = run(i, me("a"), read, claim)
    b = run(i, me("b"), read, claim)
    assert MapSet.member?(a.claimed, "43")
    refute MapSet.member?(b.claimed, "43")
  end

  test "a PR-anchored unit owned by another gateway is not dispatched" do
    {store, read, claim} = stub()
    Agent.update(store, &Map.put(&1, "pr-77", record("pr-77", @other, "x")))
    state = run(own_issue("pr-77", pr_head_ref: "feat/x"), me(), read, claim)
    refute MapSet.member?(state.claimed, "pr-77")
  end

  test "an unowned PR-anchored unit claims pr-<N> and starts" do
    {store, read, claim} = stub()
    state = run(own_issue("pr-77", pr_head_ref: "feat/x"), me(), read, claim)
    assert MapSet.member?(state.claimed, "pr-77")
    assert Map.keys(Agent.get(store, & &1)) == ["pr-77"]
  end

  test "owned by self dispatches without a write" do
    {store, read, claim} = stub()
    Agent.update(store, &Map.put(&1, "44", record("44", @g, "a")))
    claim_never = fn _, _, _, _ -> flunk("claim called") end
    state = run(own_issue("44"), me("a"), read, claim_never)
    assert MapSet.member?(state.claimed, "44")
    _ = claim
  end

  test "unknown ownership declines and the next poll with a healthy store dispatches" do
    {_store, read, claim} = stub()
    state = run(own_issue("45"), me(), fn _, _, _ -> {:unknown, :timeout} end, claim)
    refute MapSet.member?(state.claimed, "45")
    state = run(own_issue("45"), me(), read, claim)
    assert MapSet.member?(state.claimed, "45")
  end

  test "ownership off never touches the store" do
    boom = fn _, _, _ -> flunk("read called") end
    state = run(own_issue("46"), me(), boom, boom, ownership_enabled: false)
    assert MapSet.member?(state.claimed, "46")
  end

  test "a Capacity-denied ticket makes no ownership reads or writes" do
    no_read = fn _, _, _ -> flunk("read called") end
    no_claim = fn _, _, _, _ -> flunk("claim called") end

    state =
      run(own_issue("47"), me(), no_read, no_claim, capacity_admit_fun: fn _ -> {:deny, :no_slot} end)

    refute MapSet.member?(state.claimed, "47")
  end

  test "Capacity admit runs before the ownership read" do
    parent = self()
    {_store, read, claim} = stub()

    logged_read = fn r, k, o ->
      send(parent, :read)
      read.(r, k, o)
    end

    admit = fn _ ->
      send(parent, :admit)
      :admit
    end

    run(own_issue("48"), me(), logged_read, claim, capacity_admit_fun: admit)

    assert_receive :admit
    assert_receive :read
  end
end
