defmodule AiurWeb.BuildOrder.PlanningSource do
  @moduledoc """
  A pre-ticket Build Order data source: renders a build order in the spatial
  dashboard directly from a local planning pack (JSON), before any GitHub issue
  exists for the tickets.

  It implements the same `AiurWeb.BuildOrder.DataSource` behaviour as the live
  GitHub source and is selected via
  `config :aiur, :build_order_data_source, AiurWeb.BuildOrder.PlanningSource`.
  Because every downstream surface (RouteState, presenter, caches) joins on a
  GitHub `TrackerIdentity`, planning tickets are given a provisional identity
  keyed by a digest of their build order and full draft id.
  Packs with materialized GitHub mappings are
  hydrated from the daemon's current-run membership projection; pre-ticket packs
  remain planning-only.

  Production DataSource merges these local plans with supervised GitHub reads.
  This source is read-only — it never writes to GitHub. Point it
  at a pack with `:build_order_planning_pack` (an app-relative priv path).
  """

  @behaviour AiurWeb.BuildOrder.DataSource

  require Logger

  alias Aiur.BuildOrder.{Catalog, Dependency, Member, Metadata, PackStatus, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.CurrentRunMembership
  alias Aiur.DisplaySanitizer
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.DataSource

  import AiurWeb.BuildOrder.PlanningSource.MembershipHealth
  import AiurWeb.BuildOrder.PlanningSource.PackLoader

  @epoch 1
  @active_membership_lifecycles [:queued, :retrying, :allocated, :running, :paused, :waiting, :replaced]

  @doc "Resolve a pack member document without accepting a filesystem path from the request."
  @spec document(String.t(), String.t(), String.t(), String.t()) :: {:ok, String.t()} | :error
  def document(owner, repository, root_number, member_number) do
    with pack when is_map(pack) <-
           Enum.find(load_packs(include_drafts?: true), fn pack ->
             pack.repository == {owner, repository} and to_string(pack.root_number) == root_number
           end),
         ticket when is_map(ticket) <- Enum.find(pack.tickets, &(ticket_identity(pack, &1).identifier == member_number)),
         body when is_binary(body) <- draft_body(ticket.document_path, Path.dirname(pack.path)),
         {:ok, sanitized} <- DisplaySanitizer.sanitize(body, 64_000) do
      {:ok, sanitized}
    else
      _missing -> :error
    end
  end

  # --- catalog ---------------------------------------------------------------

  @impl true
  def catalog do
    membership = membership_snapshot()
    packs = load_packs()

    {provider_health, status_health, source_generation} = provider(membership, packs)

    %Snapshot{
      scope: :catalog,
      repository: catalog_repository(packs),
      generation: source_generation,
      authority_epoch: @epoch,
      data: Catalog.new(Enum.map(packs, &root_summary(&1, membership)), provider_health, search_paths: catalog_search_paths()),
      health: provider_health,
      membership_health: membership_health(membership),
      status_health: status_health
    }
  end

  # A planning catalog is read from the pack files on every `catalog/0`, so
  # there is no upstream re-converge to buy here (#2544).
  @impl true
  def refresh_catalog, do: :ok

  # --- selected root ---------------------------------------------------------

  @impl true
  def demand(%TrackerIdentity{} = identity), do: {:ok, selected_snapshot(identity)}

  @impl true
  def refresh(_identity), do: :ok

  @impl true
  def selected(%TrackerIdentity{} = identity), do: {:ok, selected_snapshot(identity)}

  defp selected_snapshot(identity) do
    membership = membership_snapshot()

    case Enum.find(load_packs(include_drafts?: true), &pack_root?(&1, identity)) do
      %{} = pack ->
        {provider_health, status_health, source_generation} = provider(membership, [pack])

        %Snapshot{
          scope: {:selected, identity},
          repository: pack.repository,
          generation: source_generation,
          authority_epoch: @epoch,
          data: SelectedRoot.new(root_summary(pack, membership), members(pack, membership), provider_health, planning?: not (pack.materialized? or pack.completed), pack_metadata: pack.metadata),
          health: provider_health,
          membership_health: membership_health(membership),
          status_health: status_health
        }

      nil ->
        {provider_health, status_health, source_generation} = provider(membership, [])
        provider_health = %{provider_health | state: :unavailable, complete?: false, failure: :pack_unavailable}

        %Snapshot{
          scope: {:selected, identity},
          repository: {"unknown", "unknown"},
          generation: source_generation,
          authority_epoch: @epoch,
          data: nil,
          health: provider_health,
          membership_health: membership_health(membership),
          status_health: status_health
        }
    end
  end

  # A selected root identity carries the pack's repository and root number.
  defp pack_root?(pack, %TrackerIdentity{owner: owner, repository: repo, identifier: number}),
    do: pack.repository == {owner, repo} and to_string(pack.root_number) == to_string(number)

  # --- runtime sources / context ---------------------------------------------

  @impl true
  def load_sources, do: DataSource.load_sources()

  @impl true
  def load_runtime_sources, do: DataSource.load_runtime_sources()

  @impl true
  def load_context(_identity), do: %{detail: :unavailable, history: :unavailable}

  # --- subscriptions ----------------------------------------------------------

  @impl true
  def subscribe_catalog, do: :ok
  @impl true
  def unsubscribe_catalog(_repository), do: :ok
  @impl true
  def subscribe_selected(_identity), do: :ok
  @impl true
  def unsubscribe_selected(_identity), do: :ok
  @impl true
  def release(_identity), do: :ok
  @impl true
  def subscribe_sources do
    with :ok <- DataSource.subscribe_sources(),
         :ok <- CurrentRunMembership.subscribe(),
         do: PackStatus.subscribe()
  end

  @impl true
  def subscribe_context(_identity), do: :ok
  @impl true
  def unsubscribe_context(_identity), do: :ok

  # --- pack -> structs -------------------------------------------------------

  defp root_summary(pack, membership) do
    identity = root_identity(pack)
    progress = progress(pack, membership)

    RootSummary.new(%{
      identity: identity,
      title: pack.title,
      icon: pack.icon,
      state: :open,
      url: issue_url(identity),
      member_count: length(pack.tickets),
      epic_count: pack.tickets |> Enum.map(& &1.lane) |> Enum.uniq() |> length(),
      phase_count: pack.tickets |> Enum.map(& &1.phase) |> Enum.uniq() |> length(),
      progress: progress.percent,
      progress_resolution: progress.resolution,
      progress_resolved_count: progress.resolved_count,
      completed?: pack.completed
    })
  end

  # Partial completion is a lower bound over the whole pack. Coverage remains
  # explicit, and a pack with no resolved members still has no numeric reading.
  defp progress(%{tickets: []}, _membership), do: %{percent: 0, resolution: :resolved, resolved_count: 0}

  defp progress(%{tickets: tickets} = pack, membership) do
    resolved = Enum.filter(tickets, &completion_known?(&1, pack, membership))
    resolved_count = length(resolved)
    completed_count = Enum.count(resolved, &completed?(&1, pack, membership))

    cond do
      resolved_count == 0 ->
        %{percent: nil, resolution: :unresolved, resolved_count: 0}

      resolved_count == length(tickets) ->
        %{percent: round(completed_count / length(tickets) * 100), resolution: :resolved, resolved_count: resolved_count}

      true ->
        %{percent: round(completed_count / length(tickets) * 100), resolution: :partial, resolved_count: resolved_count}
    end
  end

  defp members(pack, membership) do
    ids = MapSet.new(pack.tickets, & &1.id)
    tickets_by_id = Map.new(pack.tickets, &{&1.id, &1})

    identities =
      Map.new(pack.tickets, fn ticket ->
        {ticket.id, member_identity(pack, ticket, membership)}
      end)

    Enum.map(pack.tickets, fn ticket ->
      identity = Map.fetch!(identities, ticket.id)
      {state, reason} = lifecycle(ticket, identity, pack, membership)

      dependencies =
        ticket.depends_on
        |> Enum.filter(&MapSet.member?(ids, &1))
        |> Enum.map(fn dep_id ->
          planning_dependency(identity, Map.fetch!(identities, dep_id), Map.fetch!(tickets_by_id, dep_id))
        end)

      Member.new(%{
        identity: identity,
        title: ticket.title,
        url: if(is_integer(ticket.number), do: issue_url(identity), else: nil),
        document_url: if(is_nil(ticket.number), do: document_url(pack, identity), else: ticket.document_url),
        document_path: ticket.document_path,
        draft_body: ticket.draft_body,
        icon: ticket.icon,
        draft?: is_nil(ticket.number),
        state: state,
        state_reason: reason,
        labels: labels(ticket, identity, membership),
        dependencies: dependencies
      })
      |> pack_metadata(ticket)
    end)
  end

  defp pack_metadata(member, ticket) do
    metadata = Metadata.parse(pack_labels(ticket))
    metadata = if is_integer(ticket.phase) and ticket.phase >= 0, do: %{metadata | phase: ticket.phase, warnings: Enum.reject(metadata.warnings, &(&1.code == :invalid_phase))}, else: metadata
    %{member | metadata: metadata}
  end

  defp document_url(pack, identity) do
    {owner, repository} = pack.repository
    "/build-order-documents/#{owner}/#{repository}/#{pack.root_number}/#{identity.identifier}"
  end

  defp planning_dependency(identity, endpoint, %{number: number}) when is_integer(number),
    do: Dependency.new(identity, endpoint, issue_url(endpoint), :blocked_by)

  defp planning_dependency(identity, endpoint, _draft), do: Dependency.local(identity, endpoint)

  defp issue_url(%TrackerIdentity{owner: owner, repository: repo, identifier: number}),
    do: "https://github.com/#{owner}/#{repo}/issues/#{number}"

  # Ticket-backed members retain the labels already observed by the
  # orchestrator. Drafts have no live issue, so their pack metadata is the
  # authority until promotion.
  defp labels(%{number: nil} = ticket, _identity, _membership), do: pack_labels(ticket)

  defp labels(ticket, identity, membership) do
    case live_labels(identity, membership) do
      [] -> pack_labels(ticket)
      labels -> labels
    end
  end

  defp pack_labels(ticket) do
    ["build-lane:#{ticket.lane}", "phase:#{ticket.phase}"] ++
      if(ticket.complexity, do: ["complexity:#{ticket.complexity}"], else: [])
  end

  defp lifecycle(%{number: nil}, _identity, _pack, _membership), do: {"OPEN", nil}

  defp lifecycle(_ticket, identity, pack, membership) do
    case {status_lifecycle(identity, pack), membership_lifecycle(identity, membership), pack.completed} do
      {:completed, _membership, _pack_completed?} -> {"CLOSED", "COMPLETED"}
      {:cancelled, _membership, _pack_completed?} -> {"CLOSED", "NOT_PLANNED"}
      {:open, _membership, _pack_completed?} -> {"OPEN", nil}
      {nil, :completed, _pack_completed?} -> {"CLOSED", "COMPLETED"}
      {nil, :cancelled, _pack_completed?} -> {"CLOSED", "NOT_PLANNED"}
      {nil, lifecycle, false} when lifecycle in @active_membership_lifecycles -> {"OPEN", nil}
      {nil, _membership, true} -> {"CLOSED", "COMPLETED"}
      _other -> {:unknown, :unknown}
    end
  end

  defp completed?(ticket, pack, membership) do
    match?(
      {"CLOSED", "COMPLETED"},
      lifecycle(ticket, member_identity(pack, ticket, membership), pack, membership)
    )
  end

  defp completion_known?(%{number: nil}, _pack, _membership), do: true
  defp completion_known?(_ticket, %{completed: true}, _membership), do: true

  defp completion_known?(ticket, pack, membership) do
    status_lifecycle(member_identity(pack, ticket, membership), pack) in [:completed, :cancelled, :open]
  end

  defp membership_lifecycle(identity, %{members: members} = membership) when is_list(members) do
    if membership_current?(membership) do
      membership_member(identity, members)
      |> then(&Map.get(&1 || %{}, :lifecycle))
    end
  end

  defp membership_lifecycle(_identity, _membership), do: nil

  defp live_labels(identity, membership) do
    if membership_current?(membership) do
      labels =
        membership_member(identity, Map.get(membership, :members, []))
        |> then(&Map.get(&1 || %{}, :labels, []))
        |> valid_labels()

      case labels do
        [] -> membership |> Map.get(:labels_by_identity, %{}) |> Map.get(TrackerIdentity.github_key(identity), []) |> valid_labels()
        labels -> labels
      end
    else
      []
    end
  end

  defp valid_labels(labels) when is_list(labels), do: Enum.filter(labels, &is_binary/1)
  defp valid_labels(_labels), do: []

  defp member_identity(pack, %{number: nil} = ticket, _membership), do: ticket_identity(pack, ticket)

  defp member_identity(pack, ticket, %{members: members} = membership) when is_list(members) do
    identity = ticket_identity(pack, ticket)

    if membership_current?(membership) do
      case membership_member(identity, members) do
        %{identity: %TrackerIdentity{} = member_identity} -> member_identity
        _member -> identity
      end
    else
      identity
    end
  end

  defp member_identity(pack, ticket, _membership), do: ticket_identity(pack, ticket)

  defp membership_current?(%{health: :healthy, freshness: %{status: :fresh}}), do: true
  defp membership_current?(_membership), do: false

  defp membership_member(identity, members) when is_list(members), do: Enum.find(members, &same_issue?(&1, identity))
  defp membership_member(_identity, _members), do: nil

  # Canonical mappings normally contain the opaque GitHub node id, so the
  # primary match is an exact TrackerIdentity key. Older materialized packs
  # may have only github_number; their number is still an unambiguous locator
  # within the pack's repository, and the daemon projection supplies the real
  # identity without another GitHub read.
  defp same_issue?(%{identity: %TrackerIdentity{} = member_identity}, %TrackerIdentity{} = pack_identity) do
    TrackerIdentity.github_key(member_identity) == TrackerIdentity.github_key(pack_identity) ||
      same_repository_number?(member_identity, pack_identity)
  end

  defp same_issue?(_member, _pack_identity), do: false

  defp same_repository_number?(%TrackerIdentity{} = left, %TrackerIdentity{} = right) do
    String.downcase(left.owner || "") == String.downcase(right.owner || "") and
      String.downcase(left.repository || "") == String.downcase(right.repository || "") and
      left.identifier == right.identifier
  end

  defp membership_snapshot do
    snapshot = Application.get_env(:aiur, :build_order_planning_membership_snapshot, &CurrentRunMembership.snapshot/0).()

    Map.put_new(snapshot, :labels_by_identity, current_poll_labels())
  rescue
    _error -> %{health: :unavailable}
  catch
    _kind, _reason -> %{health: :unavailable}
  end

  # `StatusReport` is the in-memory result of the orchestrator's normal
  # tracker poll. Reading it adds no GitHub traffic and lets ticket-backed
  # members show current labels while their issue remains in the run snapshot.
  defp current_poll_labels do
    case StatusReport.snapshot_api() do
      snapshot when is_map(snapshot) ->
        [:running, :retrying, :idle]
        |> Enum.flat_map(&Map.get(snapshot, &1, []))
        |> Enum.reduce(%{}, &put_live_labels/2)

      _unavailable ->
        %{}
    end
  rescue
    _error -> %{}
  catch
    _kind, _reason -> %{}
  end

  defp put_live_labels(row, labels_by_identity) do
    case {Map.get(row, :tracker_identity), valid_labels(Map.get(row, :labels))} do
      {%TrackerIdentity{} = identity, [_ | _] = labels} ->
        Map.put(labels_by_identity, TrackerIdentity.github_key(identity), labels)

      _row ->
        labels_by_identity
    end
  end
end
