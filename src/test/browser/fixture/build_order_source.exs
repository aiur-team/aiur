defmodule Aiur.BrowserHarness.BuildOrderDataSource do
  @behaviour AiurWeb.BuildOrder.DataSource

  alias Aiur.BuildOrder.{Catalog, Dependency, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity

  @repository {"owner", "repo"}
  @observed_at ~U[2026-07-17 12:00:00Z]

  @impl true
  def subscribe_catalog, do: :ok

  @impl true
  def unsubscribe_catalog(_repository), do: :ok

  @impl true
  def catalog do
    entries = [
      root(42, "Release dashboard"),
      RootSummary.new(%{}),
      root(43, "Stale planning lane"),
      root(1567, "Unavailable planning graph"),
      root(1568, "Malformed planning graph"),
      root(44, "Wide planning graph")
    ]

    %Snapshot{
      scope: :catalog,
      repository: @repository,
      authority_epoch: 1,
      generation: 3,
      data: Catalog.new(entries, health(3, :healthy)),
      health: health(3, :healthy)
    }
  end

  @impl true
  def subscribe_selected(_identity), do: :ok

  @impl true
  def unsubscribe_selected(_identity), do: :ok

  @impl true
  def selected(identity), do: selected_snapshot(identity)

  @impl true
  def demand(identity), do: selected_snapshot(identity)

  @impl true
  def refresh(_identity), do: :ok

  @impl true
  def refresh_catalog, do: :ok

  @impl true
  def release(_identity), do: :ok

  @impl true
  def subscribe_sources, do: :ok

  @impl true
  def load_sources do
    %{
      execution: %{running: [], retrying: [], idle: []},
      activity: %{generation: 9, entries: [activity(identity(5))], diagnostics: %{}}
    }
  end

  @impl true
  def load_runtime_sources do
    %{
      execution: %{running: [], retrying: [], idle: []},
      activity: %{generation: 9, entries: [activity(identity(5))], diagnostics: %{}}
    }
  end

  @impl true
  def subscribe_context(_identity), do: :ok

  @impl true
  def unsubscribe_context(_identity), do: :ok

  @impl true
  def load_context(_identity),
    do: %{detail: {:error, :unavailable}, history: {:error, :unavailable}}

  defp selected_snapshot(%TrackerIdentity{identifier: "42"} = identity) do
    snapshot =
      %Snapshot{
        scope: {:selected, identity},
        repository: @repository,
        authority_epoch: 1,
        generation: 7,
        data: SelectedRoot.new(root(42, "Release dashboard"), graph_members(), health(7, :healthy)),
        health: health(7, :healthy)
      }

    {:ok, snapshot}
  end

  defp selected_snapshot(%TrackerIdentity{identifier: "43"} = identity) do
    snapshot =
      %Snapshot{
        scope: {:selected, identity},
        repository: @repository,
        authority_epoch: 1,
        generation: 8,
        data: SelectedRoot.new(root(43, "Stale planning lane"), [member(8, "Stale member")], health(8, :stale)),
        health: health(8, :stale)
      }

    {:ok, snapshot}
  end

  defp selected_snapshot(%TrackerIdentity{identifier: "1567"} = identity) do
    snapshot = %Snapshot{
      scope: {:selected, identity},
      repository: @repository,
      authority_epoch: 1,
      generation: 9,
      # #1791's reported shape: the root is known but its members could not be
      # read, so every downstream pane used to raise its own alarm about the one
      # fault. A specific read fault, not a laundered outage — the page must
      # repeat the code the provider actually reported.
      data: SelectedRoot.new(root(1567, "Unavailable planning graph"), [], unavailable_health()),
      health: unavailable_health()
    }

    {:ok, snapshot}
  end

  # The fail-closed shape: a malformed root the provider *did* return, alongside
  # provider health deliberately marked failed. The page must name the structural
  # defect, never the `rate_limited` marking that only records failing closed.
  defp selected_snapshot(%TrackerIdentity{identifier: "1568"} = identity) do
    snapshot = %Snapshot{
      scope: {:selected, identity},
      repository: @repository,
      authority_epoch: 1,
      generation: 9,
      data: SelectedRoot.new(root(1568, "Malformed planning graph"), [:malformed_member], unavailable_health()),
      health: unavailable_health()
    }

    {:ok, snapshot}
  end

  # A deliberately wide graph. The spatial view sizes one grid column per epic,
  # so a Build Order with many epics renders a stage far wider than the content
  # pane. That width must stay inside the graph's own scroll container: the
  # document itself must never scroll horizontally (#1849).
  defp selected_snapshot(%TrackerIdentity{identifier: "44"} = identity) do
    snapshot = %Snapshot{
      scope: {:selected, identity},
      repository: @repository,
      authority_epoch: 1,
      generation: 11,
      data: SelectedRoot.new(root(44, "Wide planning graph"), wide_graph_members(), health(11, :healthy)),
      health: health(11, :healthy)
    }

    {:ok, snapshot}
  end

  defp selected_snapshot(_identity), do: {:error, :unavailable}

  @wide_lane_count 14
  @wide_wave_count 4

  defp wide_graph_members do
    for wave <- 1..@wide_wave_count, lane <- 1..@wide_lane_count do
      number = 200 + (wave - 1) * @wide_lane_count + lane

      Member.new(%{
        identity: identity(number),
        title: "Wide member #{number}",
        url: issue_url(number),
        state: "OPEN",
        state_reason: nil,
        dependencies: [],
        labels: ["complexity:2", "phase:#{wave}", "build-lane:wide-epic-#{lane}"]
      })
    end
  end

  defp activity(identity) do
    %{
      identity: identity,
      status: :fresh,
      active_stage: :review,
      stage: %{status: :known, value: :review, freshness: :fresh, observed_at: @observed_at, event_id: 2},
      progress: %{
        status: :known,
        percent: 60,
        source: :checkin,
        freshness: :fresh,
        occurred_at: @observed_at,
        observed_at: @observed_at,
        event_id: 3
      },
      provenance: %{},
      observed_at: @observed_at,
      retention: :current
    }
  end

  defp graph_members do
    one = member(1, "Completed dependency", state: "CLOSED", state_reason: "COMPLETED")
    two = member(2, "Open dependency")
    three = member(3, "Not-planned dependency", state: "CLOSED", state_reason: "NOT_PLANNED")
    four = member(4, "Unknown dependency", state: "CLOSED", state_reason: "DUPLICATE")

    five =
      member(5, "Readiness target",
        dependencies: [
          dependency(5, identity(1)),
          dependency(5, identity(2)),
          dependency(5, identity(3)),
          dependency(5, identity(4)),
          Dependency.new(identity(5), identity(9, {"other", "repo"}), "https://github.com/other/repo/issues/9")
        ]
      )

    six = member(6, "Cycle one", dependencies: [dependency(6, identity(7))])
    seven = member(7, "Cycle two", dependencies: [dependency(7, identity(6))])
    [one, two, three, four, five, six, seven]
  end

  defp member(number, title, opts \\ []) do
    lane = if number == 4, do: "unrecognized-lane", else: "dashboard-ui"

    Member.new(%{
      identity: identity(number),
      title: title,
      url: issue_url(number),
      state: Keyword.get(opts, :state, "OPEN"),
      state_reason: Keyword.get(opts, :state_reason),
      dependencies: Keyword.get(opts, :dependencies, []),
      labels: ["complexity:2", "phase:1", "build-lane:#{lane}"]
    })
  end

  defp dependency(configured_number, endpoint),
    do: Dependency.new(identity(configured_number), endpoint, issue_url(endpoint.identifier))

  defp root(number, title) do
    RootSummary.new(%{
      identity: identity(number),
      title: title,
      url: issue_url(number),
      state: "OPEN",
      state_reason: nil
    })
  end

  defp identity(number, repository \\ @repository) do
    {owner, name} = repository

    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: owner,
      repository: name,
      provider_id: "NODE-#{owner}-#{name}-#{number}",
      database_id: number,
      identifier: to_string(number),
      reason: nil
    }
  end

  defp issue_url(number), do: "https://github.com/owner/repo/issues/#{number}"

  defp unavailable_health do
    ProviderHealth.new(9, :unavailable, false,
      observed_at: @observed_at,
      last_success_at: @observed_at,
      failure: :rate_limited
    )
  end

  defp health(generation, state) do
    ProviderHealth.new(generation, state, state == :healthy,
      observed_at: @observed_at,
      last_success_at: @observed_at
    )
  end
end
