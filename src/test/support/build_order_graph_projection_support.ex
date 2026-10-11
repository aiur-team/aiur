defmodule Aiur.BuildOrder.GraphProjectionTestSupport do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Aiur.BuildOrder.Catalog
  alias Aiur.BuildOrder.GitHubGraph.Normalizer
  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.ProviderHealth
  alias Aiur.BuildOrder.ProviderResult
  alias Aiur.BuildOrder.RootSummary
  alias Aiur.BuildOrder.SelectedRoot
  alias Aiur.GitHub.ResourceStore
  alias Aiur.TrackerIdentity

  @repository {"owner", "repo"}
  @now ~U[2026-07-15 12:00:00Z]

  def start_projection(opts \\ []) do
    parent = self()

    task_supervisor =
      start_supervised!(%{
        id: make_ref(),
        start: {Task.Supervisor, :start_link, [[]]}
      })

    authority = Keyword.get(opts, :authority)
    clock = Keyword.get(opts, :clock)
    max_selected_roots = Keyword.get(opts, :max_selected_roots, 4)

    authority_snapshot =
      if authority,
        do: fn -> Agent.get(authority, & &1) end,
        else: fn -> authority(@repository, 1, max_selected_roots) end

    clock_ms = if clock, do: fn -> Agent.get(clock, & &1) end, else: fn -> 0 end

    GraphProjection.start_link(
      name: nil,
      task_supervisor: task_supervisor,
      authority_snapshot: authority_snapshot,
      configuration_subscriber: fn _pid -> :ok end,
      reconciliation_fun: Keyword.get(opts, :reconciliation_fun, fn _opts -> :ok end),
      catalog_reader: Keyword.get(opts, :catalog_reader, blocking_reader(parent, :catalog)),
      selected_reader: fn identity, _reader_opts -> blocking_read(parent, {:selected, identity}) end,
      now: fn -> @now end,
      clock_ms: clock_ms,
      catalog_refresh_ms: 60_000,
      refresh_timeout_ms: 30_000,
      max_selected_roots: max_selected_roots,
      max_inflight: 4,
      member_debounce_ms: Keyword.get(opts, :member_debounce_ms, 0),
      after_broadcast: fn event -> send(parent, {:projection_event, event}) end
    )
  end

  def blocking_reader(parent, scope), do: fn _reader_opts -> blocking_read(parent, scope) end

  def blocking_read(parent, scope) do
    send(parent, {:reader_started, scope, self()})

    receive do
      {:finish, result} -> result
    end
  end

  def await_reader(scope) do
    assert_receive {:reader_started, ^scope, reader}, 2_000
    reader
  end

  def finish(reader, result), do: send(reader, {:finish, result})

  # A reconciliation that holds until the test releases it, so "one at a time"
  # can be asserted rather than raced against a stub that returns instantly.
  def blocking_reconciliation(parent) do
    fn reader_opts ->
      send(parent, {:reconciled, reader_opts, self()})

      receive do
        {:finish, result} -> result
      end
    end
  end

  def await_reconciliation_idle(projection, attempts \\ 200) do
    cond do
      is_nil(:sys.get_state(projection).reconciliation) ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        await_reconciliation_idle(projection, attempts - 1)

      true ->
        flunk("reconciliation stayed inflight")
    end
  end

  def await_selected_scope(identity) do
    assert_receive {:reader_started, {:selected, ^identity} = scope, _reader}, 2_000
    scope
  end

  def authority(repository, generation, max_selected_roots) do
    %{
      repository: repository,
      generation: generation,
      root_limit: 100,
      page_budget: 4,
      call_budget: 4,
      options: [
        catalog_refresh_ms: 60_000,
        refresh_timeout_ms: 30_000,
        max_selected_roots: max_selected_roots,
        max_inflight: 4
      ]
    }
  end

  # Brings a watched root to a steady state: the catalog holds `root_summary`
  # and the selected graph has been read against that marker.
  def read_root_at(projection, identity, root_summary) do
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root_summary]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    assert {:ok, _} = GraphProjection.demand(projection, identity)
    :ok = GraphProjection.refresh(projection, identity)
    finish(await_reader({:selected, identity}), {:ok, ProviderResult.complete(selected(identity))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: {:selected, ^identity}}}}, 2_000
  end

  # Answers every read the projection starts until it has been quiet for
  # `quiet_ms` — catalog rebuilds with `catalog`, selected reads successfully —
  # and returns how many selected reads of `identity` it bought.
  def count_selected_reads(identity, catalog, quiet_ms \\ 500, count \\ 0) do
    receive do
      {:reader_started, :catalog, reader} ->
        finish(reader, {:ok, ProviderResult.complete(catalog)})
        count_selected_reads(identity, catalog, quiet_ms, count)

      {:reader_started, {:selected, ^identity}, reader} ->
        finish(reader, {:ok, ProviderResult.complete(selected(identity))})
        count_selected_reads(identity, catalog, quiet_ms, count + 1)
    after
      quiet_ms -> count
    end
  end

  # The parent/sub-issue edge the reconciliation deposits, which is the only
  # thing `CatalogStore.member_numbers/1` resolves a member's root from.
  def seed_sub_issues(edges) do
    ResourceStore.reset()
    on_exit(fn -> if Process.whereis(ResourceStore), do: ResourceStore.reset() end)

    Enum.each(edges, fn {parent, sub} ->
      ResourceStore.put_resource(
        ResourceStore.key_for_repo(:sub_issue, "owner/repo", "#{parent}:#{sub}"),
        %{"present" => true, "parent_issue_number" => parent, "sub_issue_number" => sub},
        source: :poll,
        version: "2026-07-15T12:00:00Z"
      )
    end)
  end

  # A store deposit as the tracker poll records one: the same shape the webhook
  # path deposits, which is the point — a poll-only repository produces these
  # and nothing else.
  def issue_change(resource_type, id) do
    %{
      key: nil,
      resource_type: resource_type,
      owner: "owner",
      repo: "repo",
      id: id,
      source: :poll,
      version: nil,
      etag: nil,
      data?: true,
      data_version: nil,
      recorded_at_ms: 1,
      cleared: false
    }
  end

  def catalog(roots), do: Catalog.new(roots, ProviderHealth.new(1, :healthy, true))

  def selected(identity, repository \\ @repository) do
    SelectedRoot.new(root(identity, repository), [], ProviderHealth.new(1, :healthy, true))
  end

  def root(identity, {owner, repository} \\ @repository) do
    RootSummary.new(%{
      identity: identity,
      title: "Build Order #{identity.identifier}",
      url: "https://github.com/#{owner}/#{repository}/issues/#{identity.identifier}",
      state: "OPEN"
    })
  end

  # A root carrying the fingerprint the carry-forward rule matches on: identity,
  # member count, and update timestamp.
  def counted_root(identity, opts \\ []) do
    identity
    |> root()
    |> Map.merge(%{
      member_count: 3,
      updated_at: ~U[2026-07-15 11:00:00Z],
      epic_count: Keyword.get(opts, :epic_count),
      phase_count: Keyword.get(opts, :phase_count)
    })
  end

  # A root as the catalog GraphQL query actually returns it, put through the real
  # normalizer. `member_states` are the sub-issue lifecycles; everything about the
  # root itself is fixed, so any marker that moves between two calls moved because
  # of a *member*.
  def normalized_root(number, member_states, {owner, repo} \\ @repository) do
    members =
      Enum.map(member_states, fn
        "CLOSED" -> %{"state" => "CLOSED", "stateReason" => "COMPLETED"}
        state -> %{"state" => state, "stateReason" => nil}
      end)

    Normalizer.root(
      %{
        "id" => "I#{number}",
        "databaseId" => number,
        "number" => number,
        "title" => "Build Order #{number}",
        "url" => "https://github.com/#{owner}/#{repo}/issues/#{number}",
        "state" => "OPEN",
        "stateReason" => nil,
        "createdAt" => "2026-07-01T10:00:00Z",
        "updatedAt" => "2026-07-15T11:00:00Z",
        "repository" => %{"name" => repo, "owner" => %{"login" => owner}},
        "parent" => nil,
        "labels" => %{
          "totalCount" => 1,
          "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
          "nodes" => [%{"name" => "build-order"}]
        },
        "subIssues" => %{
          "totalCount" => length(members),
          "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
          "nodes" => members
        }
      },
      {owner, repo}
    )
  end

  def identity(number, provider_id, repository \\ @repository) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => provider_id, "number" => number},
        repository,
        repository
      )

    identity
  end
end
