defmodule Aiur.BuildQueue.ProjectionReadTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.{Catalog, Lifecycle, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildQueue.Sources.ProjectionRead
  alias Aiur.TrackerIdentity

  defmodule Projection do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(opts), do: {:ok, Map.new(opts)}
    @impl true
    def handle_call(:catalog, _from, state), do: {:reply, state.catalog, state}
    def handle_call({:selected, identity}, _from, %{identity: identity} = state), do: {:reply, {:ok, state.selected}, state}
  end

  test "held stale projection supplies canonical progress, completed count and source age" do
    {pid, health} = projection(:stale)
    result = ProjectionRead.read(2573, DateTime.to_unix(health.observed_at, :millisecond) + 920_000, pid)
    assert result.progress == %{completed: 9, resolved: 12, total: 15, percent: 60, resolution: "partial"}
    assert result.source.freshness == :stale
    assert result.source.age_ms == 920_000
    assert result.source.partial
    assert result.source.reasons == [:delivery_staleness]
  end

  test "unknown source does not present retained completion as current evidence" do
    {pid, health} = projection(:unavailable)
    result = ProjectionRead.read(2573, DateTime.to_unix(health.observed_at, :millisecond) + 920_000, pid)
    assert result.progress == %{completed: nil, resolved: nil, total: nil, percent: nil, resolution: :unknown}
    assert result.source.freshness == :unknown
    assert result.source.age_ms == 920_000
  end

  test "absent projection gives null counts rather than a completed empty plan" do
    result = ProjectionRead.read(2573, 1_000, :absent_queue_projection_test)
    assert result.progress == %{completed: nil, resolved: nil, total: nil, percent: nil, resolution: :unknown}
    assert result.source.freshness == :unknown
    assert result.source.age_ms == nil
    assert result.source.reasons == [:projection_unavailable]
  end

  defp projection(health_state) do
    identity = %TrackerIdentity{version: 1, status: :joinable, kind: :github, owner: "owner", repository: "repo", provider_id: "ROOT", identifier: "2573"}
    health = %ProviderHealth{state: health_state, generation: 1, complete?: false, observed_at: ~U[2026-10-08 00:00:00Z], failure: :delivery_staleness}
    root = %RootSummary{identity: identity, progress: 60, progress_resolution: :partial, progress_resolved_count: 12, member_count: 15}
    members = List.duplicate(%Member{lifecycle: %Lifecycle{state: :closed, state_reason: :completed}}, 9)
    catalog = %Snapshot{scope: :catalog, repository: {"owner", "repo"}, generation: 1, health: health, data: %Catalog{entries: [root]}}
    selected = %{catalog | scope: {:selected, identity}, data: %SelectedRoot{root: root, members: members, provider: health}}
    pid = start_supervised!({Projection, identity: identity, catalog: catalog, selected: selected})
    {pid, health}
  end
end
