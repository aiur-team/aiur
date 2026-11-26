defmodule Aiur.Orchestrator.OwnershipDispatchTest do
  use Aiur.DispatcherTestSupport

  alias Aiur.AgentPubSub
  alias Aiur.Capacity.LedgerStore
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

  test "unknown ownership declines with attention and the next poll with a healthy store dispatches" do
    {_store, read, claim} = stub()
    issue = own_issue("45")
    :ok = AgentPubSub.subscribe_agent(issue.identifier)
    state = run(issue, me(), fn _, _, _ -> {:unknown, :timeout} end, claim)
    refute MapSet.member?(state.claimed, "45")
    assert state.dispatch_declines["45"] == :ownership_unknown
    assert_receive {:alert, %{name: "ticket.45.agent.attention.dispatch-declined", needs_attention: true}}, 2_000
    state = run(issue, me(), read, claim)
    assert MapSet.member?(state.claimed, "45")
  end

  test "another owner declines quietly: reason recorded, no attention" do
    {store, read, claim} = stub()
    Agent.update(store, &Map.put(&1, "49", record("49", @other, "x")))
    issue = own_issue("49")
    :ok = AgentPubSub.subscribe_agent(issue.identifier)
    state = run(issue, me(), read, claim)
    refute MapSet.member?(state.claimed, "49")
    assert state.dispatch_declines["49"] == :ownership_not_owner
    refute_receive {:alert, %{name: "ticket.49.agent.attention.dispatch-declined"}}, 300
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

  describe "capacity reservation hold (#7890)" do
    setup do
      ledger = start_supervised!({LedgerStore, name: :"ledger_#{System.unique_integer([:positive])}"})
      %{ledger: ledger, hold_opts: [ledger_store: ledger, capacity_policy: %{sources: %{"codex" => %{billing: "subscription"}}}]}
    end

    defp holds(ledger), do: Map.keys(LedgerStore.ledger(ledger).holds)

    test "a started agent holds until it exits", %{ledger: ledger, hold_opts: hold_opts} do
      parent = self()

      runner = fn i, _, _ ->
        send(parent, {:running, i.id, self()})
        receive do: (:stop -> :ok)
      end

      {_store, read, claim} = stub()
      state = run(own_issue("49"), me(), read, claim, [runner: runner] ++ hold_opts)
      assert_receive {:running, "49", pid}, 1000
      assert state.running["49"].pid == pid
      assert holds(ledger) == ["49"]

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
      assert holds(ledger) == []
    end

    test "a dispatch declined after the claim leaves no hold", %{ledger: ledger, hold_opts: hold_opts} do
      no_read = fn _, _, _ -> flunk("read called") end
      no_claim = fn _, _, _, _ -> flunk("claim called") end
      run(own_issue("50"), me(), no_read, no_claim, [capacity_admit_fun: fn _ -> {:deny, :no_slot} end] ++ hold_opts)
      assert holds(ledger) == []
    end

    test "a dispatch the ownership claim loses leaves no hold", %{ledger: ledger, hold_opts: hold_opts} do
      {store, read, claim} = stub()
      Agent.update(store, &Map.put(&1, "51", record("51", @other, "x")))
      refute MapSet.member?(run(own_issue("51"), me(), read, claim, hold_opts).claimed, "51")
      assert holds(ledger) == []
    end
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

    # Both messages come from one process, so mailbox order is call order:
    # the first message must be :admit, else the read ran first.
    assert {:messages, [:admit, :read | _]} = Process.info(self(), :messages)
  end

  # The opts each of the 12 callers (MPG-103.md table) hands to do_dispatch_issue/5.
  @caller_opts [
    poll: [dependency_checked: true],
    prevalidated_resume: [dependency_checked: true],
    reactivate: [prior_work: true],
    recycle: [prior_work: true],
    remote_control_demote: [],
    account_handoff: [prior_work: true],
    backend_fallback: [prior_work: true],
    model_relabel: [],
    override_replacement: [prior_work: true, fresh_session: true]
  ]

  for {caller, opts} <- @caller_opts do
    test "caller #{caller} starts no agent when another gateway owns the ticket" do
      {store, read, claim} = stub()
      Agent.update(store, &Map.put(&1, "50", record("50", @other, "x")))
      state = run(own_issue("50"), me(), read, claim, unquote(opts))
      refute MapSet.member?(state.claimed, "50")
      refute_received {:started, "50"}
      assert state.dispatch_declines["50"] == :ownership_not_owner
    end
  end

  test "PR-anchored caller starts no agent when another gateway owns pr-<N>" do
    {store, read, claim} = stub()
    Agent.update(store, &Map.put(&1, "pr-78", record("pr-78", @other, "x")))
    state = run(own_issue("pr-78", pr_head_ref: "feat/y"), me(), read, claim)
    refute_received {:started, "pr-78"}
    assert state.dispatch_declines["pr-78"] == :ownership_not_owner
  end

  # Guard: every start path funnels through do_dispatch_issue/5 (covered above). A new
  # call site outside the known set is a new path nobody has proven refuses.
  test "orchestrator dispatch call sites are exactly the known callers" do
    root = Path.expand("../../../lib/aiur/orchestrator", __DIR__)

    sites =
      Path.wildcard(root <> "/**/*.ex")
      |> Enum.filter(&(File.read!(&1) =~ ~r/Dispatcher\.(do_dispatch_issue|dispatch_prevalidated_issue)\b/))
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()

    assert sites == [
             "override_recovery.ex",
             "override_resume.ex",
             "pause_resume/completed_replacement.ex",
             "pause_resume/queued_dispatch.ex",
             "pause_resume/resume.ex",
             "pause_resume/tracker_control.ex",
             "pr_anchored.ex",
             "rate_limit_fallback/redispatch.ex",
             "redispatch.ex",
             "remote_control_mode.ex"
           ]
  end
end
