defmodule Aiur.BuildOrdersCLIStaleReadTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.{Catalog, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.{BuildOrdersCLI, TrackerIdentity}

  @now ~U[2026-09-29 03:00:00Z]
  @old ~U[2026-09-28 22:15:00Z]

  # Boundary double: refresh completes synchronously so the next selected read
  # exposes the provider's changed lifecycle, without tracker/network access.
  defmodule Source do
    def catalog(context), do: context.catalog
    def demand(context, _identity), do: {:ok, context.held}
    def load_runtime_sources(_context), do: %{}

    def refresh(context, identity) do
      send(self(), {:refresh, identity})
      Process.put({__MODULE__, :selected}, context.refreshed)
      :ok
    end

    def selected(_context, _identity), do: {:ok, Process.get({__MODULE__, :selected})}
  end

  test "an explicit stale CLI read refreshes and reports a closed member" do
    context = context()
    assert {:ok, result} = read(context)
    assert_received {:refresh, identity}
    assert identity == context.root.identity
    assert result["sources"]["planning_graph"]["observed_at"] == DateTime.to_iso8601(@now)
    assert [%{"id" => "516", "state" => "closed"}] = result["data"]["graph"]["members"]
  end

  test "stale held data stays visible without retrying inside provider backoff" do
    context = context()
    health = %{context.held.health | failure: :rate_limited, next_retry_at: DateTime.add(@now, 60)}
    context = put_in(context.held.health, health)
    assert {:ok, result} = read(context)
    refute_received {:refresh, _}
    assert result["sources"]["planning_graph"]["freshness"] == "stale"
    assert [%{"state" => "open"}] = result["data"]["graph"]["members"]

    assert {:ok, recovered} = read(context, DateTime.add(@now, 60))
    assert_received {:refresh, _}
    assert [%{"state" => "closed"}] = recovered["data"]["graph"]["members"]
  end

  test "future regression guard: healthy and already-refreshing graphs do not request another refresh" do
    for patch <- [%{state: :healthy}, %{refreshing?: true}] do
      context = context()
      context = put_in(context.held.health, Map.merge(context.held.health, patch))
      assert {:ok, _} = read(context)
      refute_received {:refresh, _}
    end
  end

  defp read(context, now \\ @now),
    do: BuildOrdersCLI.build(root: "1", source: {Source, context}, now: now)

  defp context do
    root = RootSummary.new(%{identity: identity(1), title: "Build Order", state: "OPEN", labels: ["build-order"], member_count: 1})
    held = selected(root, :open, :stale, @old, 1)
    refreshed = selected(root, :closed, :healthy, @now, 2)
    catalog = %{held | scope: :catalog, data: Catalog.new([root], held.health)}
    %{root: root, held: held, refreshed: refreshed, catalog: catalog}
  end

  defp selected(root, state, freshness, observed_at, generation) do
    health = ProviderHealth.new(generation, freshness, true, observed_at: observed_at)
    member = Member.new(%{identity: identity(516), title: "Closed ticket", state: state, state_reason: :completed, labels: []})

    %Snapshot{
      scope: {:selected, root.identity},
      repository: {"owner", "repo"},
      generation: generation,
      health: health,
      data: SelectedRoot.new(root, [member], health)
    }
  end

  defp identity(number) do
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I#{number}", "number" => number}, {"owner", "repo"}, {"owner", "repo"})
    identity
  end
end
