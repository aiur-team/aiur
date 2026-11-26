defmodule Aiur.BuildOrder.PublishedReference do
  @moduledoc """
  Deterministic Build Order projections for the published-contract tests.

  The reference projection mirrors the reference planning pack: four
  workstreams, one external gate, one ticket of every typed relation and one
  ticket closed without completion. The same projection produces the committed
  `build-order.v1` golden document, so the encoder and the TypeScript package
  cannot drift apart.
  """

  alias Aiur.BuildOrder.{Catalog, Dependency, Lifecycle, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity

  @repository {"aiur-team", "aiur"}
  @now ~U[2026-11-04 20:15:00Z]
  @build_order_id "aiur-team/aiur:build-order-package"
  @draft_identity_number 1_000_000_000_000_000_006

  @tickets [
    %{
      id: "BO-001",
      number: 7490,
      identity_number: 7490,
      title: "Inventory Build Orders and agree the package boundary",
      lane: "plan-graph",
      phase: 1,
      complexity: 3,
      feature: "bo-research",
      kind: "executable",
      provenance: "planned",
      state: :closed,
      state_reason: :completed,
      draft?: false,
      progress: 100,
      depends_on: [],
      serializes_with: [],
      suggested_after: [],
      contains: [],
      external_gates: []
    },
    %{
      id: "BO-002",
      number: 7501,
      identity_number: 7501,
      title: "Publish the build-order.v1 schema and fixtures",
      lane: "plan-graph",
      phase: 1,
      complexity: 3,
      feature: "bo-contract",
      kind: "executable",
      provenance: "planned",
      state: :open,
      state_reason: nil,
      draft?: false,
      progress: :unknown,
      depends_on: [{"BO-001", :pack}],
      serializes_with: [],
      suggested_after: [],
      contains: [],
      external_gates: []
    },
    %{
      id: "BO-003",
      number: 7502,
      identity_number: 7502,
      title: "Encode build-order.v1 from the daemon projection",
      lane: "plan-graph",
      phase: 2,
      complexity: 3,
      feature: "bo-contract",
      kind: "executable",
      provenance: "planned",
      state: :open,
      state_reason: nil,
      draft?: false,
      progress: :unknown,
      depends_on: [{"BO-002", :pack}],
      serializes_with: ["BO-004"],
      suggested_after: [],
      contains: [],
      external_gates: []
    },
    %{
      id: "BO-004",
      number: 7503,
      identity_number: 7503,
      title: "Render the review and graph in packages/aiur-build-order",
      lane: "dashboard-ui",
      phase: 2,
      complexity: 4,
      feature: "bo-package",
      kind: "executable",
      provenance: "planned",
      state: :closed,
      state_reason: :not_planned,
      draft?: false,
      progress: :unknown,
      depends_on: [{"BO-002", :pack}],
      serializes_with: ["BO-003"],
      suggested_after: [],
      contains: ["BO-006"],
      external_gates: ["GATE-001"]
    },
    %{
      id: "BO-005",
      number: 7504,
      identity_number: 7504,
      title: "Document the published graph contract",
      lane: "dashboard-ui",
      phase: 3,
      complexity: 4,
      feature: "bo-adoption",
      kind: "audit",
      provenance: "discovered",
      state: :closed,
      state_reason: :completed,
      draft?: false,
      progress: 100,
      depends_on: [{"BO-004", :pack}],
      serializes_with: [],
      suggested_after: [],
      contains: [],
      external_gates: []
    },
    %{
      id: "BO-006",
      number: nil,
      identity_number: @draft_identity_number,
      title: "Adopt the package in the dashboard",
      lane: "docs",
      phase: 2,
      complexity: 2,
      feature: "bo-package",
      kind: "executable",
      provenance: "planned",
      state: :open,
      state_reason: nil,
      draft?: true,
      progress: :unknown,
      depends_on: [{"BO-002", :tracker}],
      serializes_with: [],
      suggested_after: ["BO-004"],
      contains: [],
      external_gates: []
    }
  ]

  @spec now() :: DateTime.t()
  def now, do: @now

  @spec source() :: module()
  def source, do: Aiur.BuildOrder.PublishedReference.Source

  @spec unavailable_source() :: module()
  def unavailable_source, do: Aiur.BuildOrder.PublishedReference.UnavailableSource

  @spec unavailable_catalog_source() :: module()
  def unavailable_catalog_source, do: Aiur.BuildOrder.PublishedReference.UnavailableCatalogSource

  defmodule Source do
    @moduledoc false
    alias Aiur.BuildOrder.PublishedReference
    def catalog, do: PublishedReference.catalog_snapshot()
    def demand(_identity), do: {:ok, PublishedReference.selected_snapshot()}
  end

  defmodule UnavailableSource do
    @moduledoc false
    alias Aiur.BuildOrder.PublishedReference
    def catalog, do: PublishedReference.catalog_snapshot()
    def demand(_identity), do: {:error, :unavailable}
  end

  defmodule UnavailableCatalogSource do
    @moduledoc false
    alias Aiur.BuildOrder.PublishedReference

    def catalog, do: PublishedReference.catalog_snapshot(health: PublishedReference.unavailable_health())
    def demand(_identity), do: {:error, :unavailable}
  end

  @spec repository() :: {String.t(), String.t()}
  def repository, do: @repository

  @spec build_order_id() :: String.t()
  def build_order_id, do: @build_order_id

  @spec encode_opts() :: keyword()
  def encode_opts, do: [now: @now, runtime: runtime_records(), estimates: %{7504 => 16.0}]

  @spec health() :: ProviderHealth.t()
  def health, do: ProviderHealth.new(4, :healthy, true, observed_at: @now)

  @spec unavailable_health() :: ProviderHealth.t()
  def unavailable_health do
    ProviderHealth.new(4, :unavailable, false, observed_at: nil, failure: :provider_unavailable)
  end

  @spec selected_snapshot(keyword()) :: Snapshot.t()
  def selected_snapshot(opts \\ []) do
    health = Keyword.get(opts, :health, health())
    identity = identity(7490)
    members = members()

    %Snapshot{
      scope: {:selected, identity},
      repository: @repository,
      generation: 4,
      authority_epoch: 1,
      data: SelectedRoot.new(root_summary(identity, members), members, health, pack_metadata: pack_metadata()),
      health: health
    }
  end

  @spec unavailable_snapshot() :: Snapshot.t()
  def unavailable_snapshot, do: selected_snapshot(health: unavailable_health())

  @spec catalog_snapshot(keyword()) :: Snapshot.t()
  def catalog_snapshot(opts \\ []) do
    health = Keyword.get(opts, :health, health())
    entries = [root_summary(identity(7490), members()), second_root()]

    %Snapshot{
      scope: :catalog,
      repository: @repository,
      generation: 4,
      authority_epoch: 1,
      data: Catalog.new(entries, health),
      health: health
    }
  end

  defp members do
    identities = Map.new(@tickets, fn ticket -> {ticket.id, identity(ticket.identity_number)} end)
    Enum.map(@tickets, &member(&1, identities))
  end

  defp member(ticket, identities) do
    Member.new(%{
      identity: identities[ticket.id],
      title: ticket.title,
      url: if(ticket.draft?, do: nil, else: issue_url(identities[ticket.id])),
      labels: labels(ticket),
      state: ticket.state,
      state_reason: ticket.state_reason,
      draft?: ticket.draft?,
      progress: ticket.progress,
      dependencies: Enum.map(ticket.depends_on, &dependency(identities, ticket, &1))
    })
  end

  defp labels(ticket) do
    [
      "build-lane:#{ticket.lane}",
      "phase:#{ticket.phase}",
      "complexity:#{ticket.complexity}",
      "feature:#{ticket.feature}"
    ]
  end

  defp dependency(identities, ticket, {blocker_id, :pack}) do
    Dependency.local(identities[ticket.id], identities[blocker_id])
  end

  defp dependency(identities, ticket, {blocker_id, :tracker}) do
    endpoint = identities[blocker_id]
    Dependency.new(identities[ticket.id], endpoint, issue_url(endpoint), :blocked_by)
  end

  defp root_summary(identity, members) do
    completed =
      Enum.count(members, fn member -> match?(%Lifecycle{state: :closed, state_reason: :completed}, member.lifecycle) end)

    RootSummary.new(%{
      identity: identity,
      title: "Decompose Build Orders into a standalone package with a published graph contract",
      icon: "cube",
      state: :open,
      url: issue_url(identity),
      member_count: length(members),
      epic_count: 1,
      phase_count: 3,
      progress: round(completed / max(length(members), 1) * 100),
      progress_resolution: :resolved,
      progress_resolved_count: length(members)
    })
  end

  defp second_root do
    identity = identity(7510)

    RootSummary.new(%{
      identity: identity,
      title: "Render the GitHub review from build-order.v1",
      icon: "document-text",
      state: :closed,
      state_reason: :completed,
      url: issue_url(identity),
      member_count: 4,
      epic_count: 1,
      phase_count: 2,
      progress: 100,
      progress_resolution: :resolved,
      progress_resolved_count: 4
    })
  end

  defp identity(number) do
    {:ok, identity} =
      TrackerIdentity.from_github(%{"node_id" => "I_#{number}", "number" => number}, @repository, @repository)

    identity
  end

  defp issue_url(identity), do: "https://github.com/aiur-team/aiur/issues/#{identity.identifier}"

  defp pack_metadata do
    %{
      "build_order_id" => @build_order_id,
      "ticket_prefix" => "BO",
      "plan_version" => 1,
      "researched_at_commit" => "c16c731ad8a5f25f0b8f3d4d1b0cd0b4f8c9c1ab",
      "workstreams" => workstreams(),
      "external_gates" => gates(),
      "label_projection" => %{"workstreams" => label_projection()},
      "ticket_relations" => relations()
    }
  end

  defp workstreams do
    [
      %{"id" => "bo-research", "title" => "Research and plan", "icon" => "magnifying-glass"},
      %{"id" => "bo-contract", "title" => "Published graph contract", "icon" => "document-text"},
      %{"id" => "bo-package", "title" => "Framework-agnostic renderer", "icon" => "paint-brush"},
      %{"id" => "bo-adoption", "title" => "Dashboard adoption", "icon" => "window"}
    ]
  end

  defp gates do
    [
      %{
        "id" => "GATE-001",
        "title" => "Approve the review page component boundary",
        "owner" => "Product operator",
        "resolution_criteria" => "The review and graph render from build-order.v1 alone, with no daemon call."
      }
    ]
  end

  defp label_projection,
    do: Map.new(workstreams(), fn workstream -> {workstream["id"], "feature:" <> workstream["id"]} end)

  defp relations do
    Map.new(@tickets, fn ticket ->
      {to_string(ticket.identity_number), Map.take(ticket, [:id, :kind, :provenance, :feature, :serializes_with, :suggested_after, :contains, :external_gates])}
    end)
  end

  defp runtime_records do
    %{
      "7490" => %{
        "status" => "done",
        "progress_percent" => 100,
        "started_at" => "2026-11-04T09:10:00Z",
        "ended_at" => "2026-11-04T14:02:00Z"
      },
      "7501" => %{"status" => "running", "progress_percent" => 40, "started_at" => "2026-11-04T19:30:00Z"},
      "7503" => %{
        "status" => "failed",
        "progress_percent" => 0,
        "started_at" => "2026-11-05T08:00:00Z",
        "ended_at" => "2026-11-05T09:41:00Z"
      },
      "7504" => %{
        "status" => "done",
        "progress_percent" => 100,
        "started_at" => "2026-11-05T10:00:00Z",
        "ended_at" => "2026-11-05T11:12:00Z"
      }
    }
  end
end
