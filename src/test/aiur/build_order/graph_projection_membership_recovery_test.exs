defmodule Aiur.BuildOrder.GraphProjectionMembershipRecoveryTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{Catalog, Member, ProviderHealth, ProviderResult, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.TrackerIdentity

  @interval 60_000
  @repository {"owner", "repo"}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    unless Process.whereis(Aiur.PubSub), do: start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    :ok
  end

  for mode <- [:delivering, :unproven] do
    test "missing membership delivery converges while webhook mode is #{mode}" do
      {projection, clock, upstream} = start_projection()
      assert_receive {:reconciling, boot}, 1_000
      send(boot, {:finish, projection, [10]})
      await(fn -> member_count(projection) == 1 end)
      await(fn -> is_nil(:sys.get_state(projection).reconciliation) end)
      root = identity(1)
      assert {:ok, _} = GraphProjection.demand(projection, root)
      GraphProjection.refresh(projection, root)
      await(fn -> selected_members(projection, root) == ["10"] end)

      # Mode changes are not a proof that every membership event was received.
      send(projection, {:webhook_mode_changed, %{repo: "owner/repo", state: unquote(mode)}})
      # Only the external reconciliation knows the newly added members.
      Agent.update(upstream, &Map.put(&1, :next_members, [10, 592, 609]))
      state = :sys.get_state(projection)
      assert %{token: token, timer_ref: ref} = state.reconciliation_timer
      assert is_integer(Process.read_timer(ref))
      Agent.update(clock, fn _ -> @interval end)
      send(projection, {:reconcile_membership, token})
      assert_receive {:reconciling, recovery}, 1_000
      # A duplicate expired timer and concurrent resource events cannot fan out.
      send(projection, {:reconcile_membership, token})
      send(projection, {:github_resource_changed, change()})
      refute_receive {:reconciling, _}, 30
      send(recovery, {:finish, projection, Agent.get(upstream, & &1.next_members)})
      await(fn -> member_count(projection) == 3 end)
      await(fn -> selected_members(projection, root) == ["10", "592", "609"] end)
      await(fn -> is_nil(:sys.get_state(projection).reconciliation) end)
      # A fresh completion resets the bound; early timer delivery buys no read.
      current = :sys.get_state(projection).reconciliation_timer.token
      send(projection, {:reconcile_membership, current})
      refute_receive {:reconciling, _}, 30
    end
  end

  test "a reconciliation deposit is read after an older catalog read completes" do
    {projection, _clock, upstream} = start_projection(@interval, true)
    assert_receive {:reconciling, boot}, 1_000
    assert_receive {:catalog_read_before_deposit, stale_reader}, 1_000

    send(boot, {:finish, projection, [10]})
    await(fn -> Agent.get(upstream, & &1.members) == [10] end)
    # The deposit signal reaches the projection while the first reader still
    # holds its empty snapshot. A second read must be queued for that signal.
    await(fn -> MapSet.member?(:sys.get_state(projection).pending, :catalog) end)
    send(stale_reader, :finish_catalog_read)
    await(fn -> member_count(projection) == 1 end)
  end

  test "failed background reconciliation is retried after the bound without a resource event" do
    {projection, clock, _upstream} = start_projection(100)
    assert_receive {:reconciling, boot}, 1_000
    send(boot, {:finish, projection, [10]})
    await(fn -> member_count(projection) == 1 and is_nil(:sys.get_state(projection).reconciliation) end)
    Agent.update(clock, fn _ -> 100 end)
    assert_receive {:reconciling, failed}, 1_000
    send(failed, :fail)
    await(fn -> is_nil(:sys.get_state(projection).reconciliation) end)
    assert member_count(projection) == 1
    Agent.update(clock, fn _ -> 200 end)
    assert_receive {:reconciling, retry}, 1_000
    send(retry, {:finish, projection, [592, 609]})
    await(fn -> member_count(projection) == 2 end)
  end

  defp start_projection(interval \\ @interval, block_empty_catalog? \\ false) do
    parent = self()
    clock = start_supervised!({Agent, fn -> 0 end}, id: :clock)
    upstream = start_supervised!({Agent, fn -> %{members: []} end}, id: :upstream)
    supervisor = start_supervised!({Task.Supervisor, name: nil})

    # External reconciliation boundary: supplies a complete upstream membership
    # and publishes its store-change signal, just as Reconciliation.run does.
    reconcile = fn _opts ->
      send(parent, {:reconciling, self()})

      receive do
        {:finish, projection, members} ->
          Agent.update(upstream, &Map.put(&1, :members, members))
          send(projection, {:github_resource_changed, change()})
          {:ok, :reconciled, %{roots: 1}}

        :fail ->
          {:error, :unreachable}
      end
    end

    projection =
      start_supervised!(
        {GraphProjection,
         name: nil,
         task_supervisor: supervisor,
         configuration_subscriber: fn _ -> :ok end,
         resource_subscription: fn _ -> :ok end,
         mode_events_subscriber: fn -> :ok end,
         authority_snapshot: fn -> %{repository: @repository, generation: 1, options: [reconciliation_cooldown_ms: interval]} end,
         clock_ms: fn -> Agent.get(clock, & &1) end,
         reconciliation_fun: reconcile,
         catalog_reader: fn _ ->
           members = Agent.get(upstream, & &1.members)

           if block_empty_catalog? and members == [] do
             send(parent, {:catalog_read_before_deposit, self()})

             receive do
               :finish_catalog_read -> :ok
             end
           end

           {:ok, ProviderResult.complete(Catalog.new([root(members)], healthy()))}
         end,
         selected_reader: fn _, _ ->
           members = Agent.get(upstream, & &1.members)
           nodes = Enum.map(members, &Member.new(%{identity: identity(&1), title: "member", url: "https://github.com/owner/repo/issues/#{&1}", state: :open}))
           {:ok, ProviderResult.complete(SelectedRoot.new(root(members), nodes, healthy()))}
         end}
      )

    {projection, clock, upstream}
  end

  defp member_count(projection) do
    case GraphProjection.catalog(projection).data do
      %Catalog{entries: [root]} -> root.member_count
      _ -> nil
    end
  end

  defp selected_members(projection, root) do
    case GraphProjection.selected(projection, root) do
      {:ok, %{data: %SelectedRoot{members: members}}} -> Enum.map(members, & &1.identity.identifier)
      _ -> []
    end
  end

  defp root(members),
    do:
      RootSummary.new(%{
        identity: identity(1),
        title: "root",
        url: "https://github.com/owner/repo/issues/1",
        state: "OPEN",
        labels: ["build-order"],
        member_count: length(members),
        updated_at: ~U[2026-09-30 00:00:00Z]
      })

  defp healthy, do: ProviderHealth.new(1, :healthy, true)
  defp change, do: %{resource_type: :sub_issue, owner: "owner", repo: "repo", id: "1:592", cleared: true}

  defp identity(number) do
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I#{number}", "number" => number}, @repository, @repository)
    identity
  end

  defp await(fun, attempts \\ 100)
  defp await(_fun, 0), do: flunk("projection failed to converge")

  defp await(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await(fun, attempts - 1)
        )
  end
end
