defmodule AiurWeb.BuildOrder.PlanningSource do
  @moduledoc """
  The default Build Order data source. It renders the materialized planning packs
  discovered for the daemon's tracked repository, including packs before any
  GitHub issue exists for their tickets. Repositories with no discovered packs
  keep the live GitHub catalog; unknown selected roots do the same.

  It implements the same `AiurWeb.BuildOrder.DataSource` behaviour as the live
  GitHub source and is selected via
  `config :aiur, :build_order_data_source, AiurWeb.BuildOrder.PlanningSource`.
  Because every downstream surface (RouteState, presenter, caches) joins on a
  GitHub `TrackerIdentity`, planning tickets are given a provisional identity
  keyed by their numeric ticket id. Packs with materialized GitHub mappings are
  hydrated from the daemon's current-run membership projection; pre-ticket packs
  remain planning-only.

  Discovery gives publisher workspace mirrors definition precedence over their
  repository state-node copies because they are the freshest published intent;
  matching state copies still supply daemon-owned status projections. This
  source is read-only and never writes to GitHub. Ticket context continues to
  use the live detail/history providers. Use
  `:build_order_planning_pack` for a single focused demo/test pack or
  `:build_order_planning_packs` for an explicit test catalog.
  """

  @behaviour AiurWeb.BuildOrder.DataSource

  require Logger

  alias Aiur.BuildOrder.{Catalog, Dependency, Diagnostic, Member, PackPaths, PackStatus, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.CurrentRunMembership
  alias Aiur.GitHub.Config
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.DataSource

  @epoch 1
  @generation 1
  @default_root_number_base 100_000
  @default_root_number_range 800_000_000
  @pack_source_precedence %{workspace: 0, state: 1, override: 2, configured: 3, explicit: 4}
  @pack_source_precedence_description "workspace > state > environment > configured > explicit"

  # --- catalog ---------------------------------------------------------------

  @impl true
  def catalog do
    membership = membership_snapshot()
    packs = load_packs()
    live_catalog = live_catalog()

    if packs == [] and no_catalog_override?() do
      live_catalog
    else
      {provider_health, source_generation} = provider(membership, packs)

      %Snapshot{
        scope: :catalog,
        repository: catalog_repository(packs),
        generation: source_generation,
        authority_epoch: @epoch,
        data:
          packs
          |> Enum.map(&root_summary(&1, membership))
          |> union_live_catalog(live_catalog)
          |> Catalog.new(provider_health, search_paths: catalog_search_paths())
          |> append_live_catalog_diagnostics(live_catalog),
        health: provider_health
      }
    end
  end

  # --- selected root ---------------------------------------------------------

  # A root the daemon has no pack for is not "empty" — it is a live GitHub root
  # this source cannot describe, so the live source answers for it rather than
  # this one returning a data-less snapshot that renders as a blank row.
  @impl true
  def demand(%TrackerIdentity{} = identity) do
    case pack_for(identity) do
      %{} = pack -> {:ok, selected_snapshot(pack, identity)}
      nil -> DataSource.demand(identity)
    end
  end

  @impl true
  def selected(%TrackerIdentity{} = identity) do
    case pack_for(identity) do
      %{} = pack -> {:ok, selected_snapshot(pack, identity)}
      nil -> DataSource.selected(identity)
    end
  end

  defp selected_snapshot(pack, identity) do
    membership = membership_snapshot()
    {provider_health, source_generation} = provider(membership, [pack])

    %Snapshot{
      scope: {:selected, identity},
      repository: pack.repository,
      generation: source_generation,
      authority_epoch: @epoch,
      data: SelectedRoot.new(root_summary(pack, membership), members(pack, membership), provider_health, planning?: not (pack.materialized? or pack.completed)),
      health: provider_health
    }
  end

  # A selected root identity carries the pack's repository and root number.
  defp pack_root?(pack, %TrackerIdentity{owner: owner, repository: repo, identifier: number}),
    do: pack.repository == {owner, repo} and to_string(pack.root_number) == to_string(number)

  # --- runtime sources / context ---------------------------------------------

  @impl true
  def load_sources, do: DataSource.load_sources()

  @impl true
  def load_runtime_sources, do: DataSource.load_runtime_sources()

  # A live-only root has no pack here, so context must come from the live
  # source; answering `:unavailable` would render a selectable union row blank.
  @impl true
  def load_context(identity), do: DataSource.load_context(identity)

  # --- subscriptions ----------------------------------------------------------

  @impl true
  def subscribe_catalog, do: DataSource.subscribe_catalog()
  @impl true
  def unsubscribe_catalog(repository), do: DataSource.unsubscribe_catalog(repository)
  @impl true
  def subscribe_selected(identity) do
    if pack_for(identity), do: :ok, else: DataSource.subscribe_selected(identity)
  end

  @impl true
  def unsubscribe_selected(identity), do: DataSource.unsubscribe_selected(identity)
  @impl true
  def release(identity), do: DataSource.release(identity)
  @impl true
  def subscribe_sources do
    with :ok <- DataSource.subscribe_sources(),
         :ok <- CurrentRunMembership.subscribe(),
         do: PackStatus.subscribe()
  end

  @impl true
  def subscribe_context(identity), do: DataSource.subscribe_context(identity)
  @impl true
  def unsubscribe_context(identity), do: DataSource.unsubscribe_context(identity)

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

  defp pack_for(identity), do: Enum.find(load_packs(include_drafts?: true), &pack_root?(&1, identity))

  # Completion is resolved per ticket and can fail for any subset of a pack.
  # An empty pack is genuinely 0% of nothing; a pack where nothing resolves is
  # `:unresolved` and must never be reported as a number. In between, the
  # percentage is the completion rate over the tickets that *did* resolve, and
  # `resolved_count` carries the coverage so the surface can say what the
  # number is actually of. Unknown tickets are excluded from the denominator
  # rather than counted as incomplete.
  defp progress(%{tickets: []}, _membership), do: %{percent: 0, resolution: :resolved, resolved_count: 0}

  defp progress(%{tickets: tickets} = pack, membership) do
    resolved = Enum.filter(tickets, &completion_known?(&1, pack, membership))
    resolved_count = length(resolved)
    completed_count = Enum.count(resolved, &completed?(&1, pack, membership))

    cond do
      resolved_count == 0 ->
        %{percent: nil, resolution: :unresolved, resolved_count: 0}

      resolved_count == length(tickets) ->
        %{percent: round(completed_count / resolved_count * 100), resolution: :resolved, resolved_count: resolved_count}

      true ->
        %{percent: round(completed_count / resolved_count * 100), resolution: :partial, resolved_count: resolved_count}
    end
  end

  # The catalog is a union, not a fallback: an on-disk pack supplies the richer
  # definition when it shares a root with GitHub, while a GitHub-only root stays
  # visible until it is materialized. The numeric repository-qualified locator
  # is deliberate because a pack can predate the root's opaque GitHub node id.
  # A live row whose identity did not survive structural validation is skipped
  # rather than keyed against a pack: `Catalog.new/3` has already recorded the
  # diagnostic that keeps its absence visible, and an unkeyed row would collapse
  # an unrelated pack.
  defp union_live_catalog(pack_entries, live_catalog) do
    tracked_repository = configured_repository_tuple()

    packed_keys =
      for %RootSummary{identity: %TrackerIdentity{} = identity} <- pack_entries, into: MapSet.new(), do: root_key(identity)

    live_entries =
      for %RootSummary{identity: %TrackerIdentity{} = identity} = entry <- live_catalog_entries(live_catalog),
          same_repository?({identity.owner, identity.repository}, tracked_repository),
          not MapSet.member?(packed_keys, root_key(identity)),
          do: entry

    pack_entries ++ live_entries
  end

  defp live_catalog_entries(%Snapshot{data: %Catalog{entries: entries}}), do: entries
  defp live_catalog_entries(_live_catalog), do: []

  defp root_key(%TrackerIdentity{} = identity),
    do: {String.downcase(identity.owner || ""), String.downcase(identity.repository || ""), to_string(identity.identifier)}

  defp append_live_catalog_diagnostics(catalog, %Snapshot{data: %Catalog{} = live, health: health}) do
    merged = live.diagnostics ++ unusable_provider_diagnostics(health) ++ unkeyed_row_diagnostics(live.entries)
    %{catalog | diagnostics: Enum.uniq_by(catalog.diagnostics ++ merged, & &1.code)}
  end

  defp append_live_catalog_diagnostics(catalog, _live_catalog) do
    %{catalog | diagnostics: Enum.uniq_by([Diagnostic.new(:provider_unavailable) | catalog.diagnostics], & &1.code)}
  end

  defp unusable_provider_diagnostics(health),
    do: if(ProviderHealth.usable?(health), do: [], else: [Diagnostic.new(:provider_unavailable)])

  # Skipping an unkeyed live row is still an omission, so it is reported rather
  # than left to look like a catalog that simply had fewer roots.
  defp unkeyed_row_diagnostics(entries) do
    if Enum.all?(entries, &match?(%RootSummary{identity: %TrackerIdentity{}}, &1)),
      do: [],
      else: [Diagnostic.new(:invalid_root)]
  end

  defp live_catalog do
    Application.get_env(:aiur, :build_order_planning_live_catalog, &DataSource.catalog/0).()
  rescue
    _error -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  defp no_catalog_override? do
    is_nil(Application.get_env(:aiur, :build_order_planning_pack)) and
      is_nil(Application.get_env(:aiur, :build_order_planning_packs))
  end

  defp members(pack, membership) do
    ids = MapSet.new(pack.tickets, & &1.id)

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
          Dependency.new(identity, Map.fetch!(identities, dep_id), nil, :blocked_by)
        end)

      Member.new(%{
        identity: identity,
        title: ticket.title,
        url: issue_url(identity),
        document_url: ticket.document_url,
        document_path: ticket.document_path,
        draft_body: ticket.draft_body,
        icon: ticket.icon,
        draft?: is_nil(ticket.number),
        state: state,
        state_reason: reason,
        labels: labels(ticket, identity, membership),
        dependencies: dependencies
      })
    end)
  end

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

  defp root_identity(pack), do: identity!(pack.repository, pack.root_number, pack.root_node_id || "BO_ROOT")

  defp ticket_identity(pack, ticket) do
    number = ticket_number(pack, ticket)
    identity!(pack.repository, number, ticket.node_id || "PLAN_#{ticket.id}")
  end

  # Prefer the pack's real GitHub number when present; otherwise derive it from
  # the ticket id so blocker edges still resolve for pre-ticket packs.
  defp ticket_number(pack, %{id: id}) do
    case Map.get(pack.numbers, id) do
      number when is_integer(number) -> number
      _missing -> synthetic_ticket_number(id)
    end
  end

  # CT-101 -> 101. Falls back to a stable hash for non-numeric ids.
  defp synthetic_ticket_number(id) do
    case id |> String.split(~r/\D+/, trim: true) |> List.last() do
      nil -> :erlang.phash2(id, 8000) + 1
      digits -> String.to_integer(digits)
    end
  end

  defp identity!({owner, repo}, number, node_id) do
    {:ok, identity} =
      TrackerIdentity.from_github(%{"node_id" => node_id, "number" => number}, {owner, repo}, {owner, repo})

    identity
  end

  defp provider(membership, packs) do
    pack_status_snapshot = pack_status_health_snapshot()
    pack_status = pack_status_health(packs, pack_status_snapshot)
    source_generation = source_generation(membership, pack_status_snapshot)

    health =
      membership
      |> membership_health()
      |> combine_pack_status(pack_status, membership)
      |> Map.put(:generation, source_generation)

    {health, source_generation}
  end

  defp membership_health(%{health: :healthy, freshness: %{status: :fresh}} = membership) do
    ProviderHealth.new(generation(membership), :healthy, true, observed_at: DateTime.utc_now())
  end

  defp membership_health(%{health: :healthy, freshness: %{status: status}} = membership)
       when status in [:stale, :unknown] do
    ProviderHealth.new(generation(membership), :stale, false, observed_at: DateTime.utc_now(), failure: :membership_stale)
  end

  defp membership_health(%{health: :healthy, freshness: %{status: :unavailable}} = membership) do
    ProviderHealth.new(generation(membership), :unavailable, false,
      observed_at: DateTime.utc_now(),
      failure: :membership_unavailable
    )
  end

  defp membership_health(%{health: {:degraded, _reason}} = membership) do
    ProviderHealth.new(generation(membership), :stale, false, observed_at: DateTime.utc_now(), failure: :membership_stale)
  end

  defp membership_health(%{health: {:unavailable, _reason}} = membership) do
    ProviderHealth.new(generation(membership), :unavailable, false,
      observed_at: DateTime.utc_now(),
      failure: :membership_unavailable
    )
  end

  defp membership_health(%{health: :unavailable} = membership) do
    ProviderHealth.new(generation(membership), :unavailable, false,
      observed_at: DateTime.utc_now(),
      failure: :membership_unavailable
    )
  end

  defp membership_health(membership), do: ProviderHealth.new(generation(membership), :healthy, true, observed_at: DateTime.utc_now())

  defp pack_status_health(packs, snapshot) do
    packs
    |> pack_status_facts()
    |> project_pack_status_health(snapshot)
  end

  defp project_pack_status_health({false, _present?, _complete?}, _snapshot), do: nil

  defp project_pack_status_health({true, true, false}, snapshot) do
    %{snapshot | state: :stale, complete?: false, failure: snapshot.failure || :pack_status_incomplete}
  end

  defp project_pack_status_health({true, false, false}, snapshot) do
    %{snapshot | state: :unavailable, complete?: false, failure: snapshot.failure || :pack_status_incomplete}
  end

  defp project_pack_status_health({true, true, true}, %{state: :unavailable} = snapshot) do
    %{snapshot | state: :stale}
  end

  defp project_pack_status_health({true, _present?, true}, snapshot), do: snapshot

  defp pack_status_facts(packs) do
    Enum.reduce(packs, {false, false, true}, fn pack, facts ->
      Enum.reduce(pack.tickets, facts, fn ticket, {required?, projection_present?, projection_complete?} ->
        identity = ticket_identity(pack, ticket)
        requires_projection? = is_integer(ticket.number)
        known? = status_lifecycle(identity, pack) in [:completed, :cancelled, :open]

        {
          required? or requires_projection?,
          projection_present? or known?,
          projection_complete? and (not requires_projection? or known?)
        }
      end)
    end)
  end

  defp pack_status_health_snapshot do
    Application.get_env(:aiur, :build_order_pack_status_health_snapshot, &PackStatus.health/0).()
  rescue
    _error -> ProviderHealth.new(:unknown, :unavailable, false, failure: :pack_status_unavailable)
  catch
    _kind, _reason -> ProviderHealth.new(:unknown, :unavailable, false, failure: :pack_status_unavailable)
  end

  defp combine_pack_status(membership_health, nil, _membership), do: membership_health

  defp combine_pack_status(%ProviderHealth{state: :unavailable} = membership_health, _pack_status, _membership),
    do: membership_health

  defp combine_pack_status(membership_health, %ProviderHealth{state: :healthy}, _membership), do: membership_health

  defp combine_pack_status(membership_health, %ProviderHealth{} = pack_status, membership) do
    state =
      if membership_health.state == :stale or pack_status.state == :stale do
        :stale
      else
        :unavailable
      end

    ProviderHealth.new(generation(membership), state, false,
      observed_at: pack_status.observed_at,
      last_success_at: pack_status.last_success_at,
      last_attempt_at: pack_status.last_attempt_at,
      failure: pack_status.failure || :pack_status_unavailable,
      retry_count: pack_status.retry_count,
      refreshing?: pack_status.refreshing?
    )
  end

  defp generation(%{generation: generation}) when is_integer(generation) and generation >= 0, do: @generation + generation
  defp generation(_membership), do: @generation

  defp source_generation(membership, %ProviderHealth{generation: pack_generation})
       when is_integer(pack_generation) and pack_generation > 0 do
    membership_generation = generation(membership)
    sum = membership_generation + pack_generation
    div(sum * (sum + 1), 2) + pack_generation
  end

  defp source_generation(membership, _pack_status), do: generation(membership)

  defp lifecycle(%{number: nil}, _identity, _pack, _membership), do: {"OPEN", nil}

  defp lifecycle(_ticket, identity, pack, membership) do
    case {status_lifecycle(identity, pack), membership_lifecycle(identity, membership), pack.completed} do
      {:completed, _membership, _pack_completed?} -> {"CLOSED", "COMPLETED"}
      {:cancelled, _membership, _pack_completed?} -> {"CLOSED", "NOT_PLANNED"}
      {:open, _membership, _pack_completed?} -> {"OPEN", nil}
      {nil, :completed, _pack_completed?} -> {"CLOSED", "COMPLETED"}
      {nil, :cancelled, _pack_completed?} -> {"CLOSED", "NOT_PLANNED"}
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

  defp membership_lifecycle(identity, %{members: members}) when is_list(members) do
    membership_member(identity, members)
    |> then(&Map.get(&1 || %{}, :lifecycle))
  end

  defp membership_lifecycle(_identity, _membership), do: nil

  defp live_labels(identity, membership) do
    labels =
      membership_member(identity, Map.get(membership, :members, []))
      |> then(&Map.get(&1 || %{}, :labels, []))
      |> valid_labels()

    case labels do
      [] -> membership |> Map.get(:labels_by_identity, %{}) |> Map.get(TrackerIdentity.github_key(identity), []) |> valid_labels()
      labels -> labels
    end
  end

  defp valid_labels(labels) when is_list(labels), do: Enum.filter(labels, &is_binary/1)
  defp valid_labels(_labels), do: []

  defp member_identity(pack, %{number: nil} = ticket, _membership), do: ticket_identity(pack, ticket)

  defp member_identity(pack, ticket, %{members: members}) when is_list(members) do
    identity = ticket_identity(pack, ticket)

    case membership_member(identity, members) do
      %{identity: %TrackerIdentity{} = member_identity} -> member_identity
      _member -> identity
    end
  end

  defp member_identity(pack, ticket, _membership), do: ticket_identity(pack, ticket)

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

  # --- pack loading ----------------------------------------------------------

  defp load_packs(options \\ []) do
    include_drafts? = Keyword.get(options, :include_drafts?, false)

    pack_paths()
    |> Enum.map(&load_pack(&1, include_drafts?))
    |> Enum.flat_map(fn
      {:ok, pack} -> [pack]
      :error -> []
    end)
    |> filter_for_tracked_repository()
    |> reconcile_duplicate_packs()
    |> Enum.sort(&pack_before?/2)
    |> assign_default_root_numbers()
    |> assign_default_icons()
  end

  # A single explicit pack is a test/demo override. Every normal catalog source,
  # including the environment directory override, remains scoped to the repo this
  # daemon is tracking.
  defp filter_for_tracked_repository(packs) do
    if Application.get_env(:aiur, :build_order_planning_pack) do
      packs
    else
      Enum.filter(packs, &tracked_repository?/1)
    end
  end

  defp tracked_repository?(%{repository: repository}), do: same_repository?(repository, configured_repository_tuple())
  defp tracked_repository?(_pack), do: false

  defp pack_paths do
    case Application.get_env(:aiur, :build_order_planning_pack) do
      nil ->
        case Application.get_env(:aiur, :build_order_planning_packs) do
          paths when is_list(paths) -> Enum.map(paths, &{:configured, &1})
          _missing -> discovered_packs()
        end

      path ->
        [{:explicit, path}]
    end
  end

  # Runtime packs are re-discovered through the same canonical source list the
  # status poller uses, including publisher-created workspace mirrors.
  defp discovered_packs do
    PackPaths.discovered_sources()
  end

  defp catalog_repository([pack | _packs]), do: pack.repository
  defp catalog_repository([]), do: configured_repository_tuple()

  defp configured_repository_tuple do
    case String.split(to_string(configured_repository() || ""), "/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" -> {owner, repo}
      _other -> {"unknown", "unknown"}
    end
  end

  defp catalog_search_paths do
    case Application.get_env(:aiur, :build_order_planning_pack) do
      nil ->
        case Application.get_env(:aiur, :build_order_planning_packs) do
          paths when is_list(paths) -> Enum.map(paths, &Path.dirname(absolute_path(&1)))
          _missing -> PackPaths.discovery_directories()
        end

      path ->
        [Path.dirname(absolute_path(path))]
    end
  end

  defp load_pack({source, path}, include_drafts?) do
    absolute = absolute_path(path)

    with {:ok, body} <- File.read(absolute),
         {:ok, json} <- Jason.decode(body),
         {:ok, repository} <- repository(json),
         {:ok, tickets} <- tickets(Map.get(json, "tickets", []), Path.dirname(absolute), include_drafts?) do
      raw_build_order_id = Map.get(json, "build_order_id")
      build_order_id = normalized_build_order_id(raw_build_order_id)
      root_number = Map.get(json, "root_number") || get_in(json, ["github_root", "number"])
      status = status(absolute)
      declared_completed? = Map.get(json, "completed", false) == true

      {:ok,
       %{
         source: source,
         path: absolute,
         content_hash: :crypto.hash(:sha256, body),
         repository: repository,
         build_order_id: build_order_id,
         build_order_id_explicit?: is_binary(raw_build_order_id) and raw_build_order_id != "",
         title: Map.get(json, "title", "Planning build order"),
         icon: pack_icon(json),
         icon_explicit?: is_binary(Map.get(json, "icon")) and Map.get(json, "icon") != "",
         root_number: root_number || default_root_number(build_order_id),
         root_number_explicit?: is_integer(root_number),
         root_node_id: root_node_id(json, build_order_id),
         declared_completed?: declared_completed?,
         completed: declared_completed? or status_completed?(status),
         completed_at: status_completed_at(status),
         status: status,
         materialized?: Enum.any?(tickets, &is_integer(&1.number)),
         tickets: tickets,
         numbers: ticket_numbers(tickets)
       }}
    else
      _error -> :error
    end
  end

  # The publisher writes a workspace mirror while the repository state node
  # retains its canonical copy. Reconcile only mirrors of the same logical
  # build order before sorting so the URL router receives one root identity.
  # Source precedence is intentional and auditable in the warning: workspace,
  # state, environment, configured list, then the singular explicit test/demo
  # pack. Distinct build orders retain their entries even when root locators
  # collide, allowing RouteState to fail closed rather than hiding a pack.
  defp reconcile_duplicate_packs(packs) do
    packs
    |> Enum.sort_by(&pack_precedence/1)
    |> Enum.reduce([], fn pack, selected ->
      case Enum.find_index(selected, &same_catalog_pack?(&1, pack)) do
        nil ->
          [pack | selected]

        index ->
          chosen = Enum.at(selected, index)

          Logger.warning(
            "build order catalog discarded #{duplicate_kind(chosen, pack)} #{inspect(pack.build_order_id)} from #{pack.source} (#{pack.path}); " <>
              "source precedence #{@pack_source_precedence_description} selected #{chosen.source} (#{chosen.path})"
          )

          List.replace_at(selected, index, retain_state_projection(chosen, pack))
      end
    end)
    |> Enum.reverse()
  end

  defp pack_precedence(pack), do: {Map.get(@pack_source_precedence, pack.source, 99), pack.path}

  defp same_catalog_pack?(left, right) do
    same_repository?(left.repository, right.repository) and
      left.build_order_id_explicit? and right.build_order_id_explicit? and
      left.build_order_id == right.build_order_id
  end

  defp duplicate_kind(%{content_hash: hash}, %{content_hash: hash}), do: "identical mirror"
  defp duplicate_kind(_chosen, _pack), do: "divergent duplicate"

  # A workspace mirror determines the catalog definition, but the daemon writes
  # status.json only beside the repository-state manifest. Keep that projection
  # when the matching state pack loses definition precedence.
  defp retain_state_projection(chosen, %{source: :state, status: status}) do
    %{chosen | status: status, completed: chosen.declared_completed? or status_completed?(status), completed_at: status_completed_at(status)}
  end

  defp retain_state_projection(chosen, _discarded), do: chosen

  defp same_repository?({left_owner, left_repo}, {right_owner, right_repo}) do
    String.downcase(left_owner) == String.downcase(right_owner) and String.downcase(left_repo) == String.downcase(right_repo)
  end

  defp same_repository?(_left, _right), do: false

  defp normalized_build_order_id(build_order_id) when is_binary(build_order_id) and build_order_id != "", do: build_order_id
  defp normalized_build_order_id(_build_order_id), do: "planning"

  defp ticket_numbers(tickets) do
    for %{id: id, number: number} <- tickets, is_integer(number), into: %{}, do: {id, number}
  end

  defp root_node_id(json, build_order_id), do: Map.get(json, "root_node_id") || get_in(json, ["github_root", "node_id"]) || "BO_#{build_order_id}"

  defp assign_default_root_numbers(packs) do
    {packs, _used_numbers} =
      Enum.map_reduce(packs, MapSet.new(), fn pack, used_numbers ->
        root_number =
          if pack.root_number_explicit? do
            pack.root_number
          else
            unique_default_root_number(pack.build_order_id, used_numbers)
          end

        {%{pack | root_number: root_number}, MapSet.put(used_numbers, root_number)}
      end)

    packs
  end

  defp default_root_number(build_order_id), do: @default_root_number_base + :erlang.phash2(build_order_id, @default_root_number_range)

  defp unique_default_root_number(build_order_id, used_numbers, probe \\ 0) do
    root_number = default_root_number({build_order_id, probe})

    if MapSet.member?(used_numbers, root_number) do
      unique_default_root_number(build_order_id, used_numbers, probe + 1)
    else
      root_number
    end
  end

  defp repository(json) do
    case String.split(to_string(Map.get(json, "repository", "")), "/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" -> {:ok, {owner, repo}}
      _other -> :error
    end
  end

  defp tickets(list, pack_dir, include_drafts?) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn attributes, {:ok, tickets} ->
      case ticket(attributes, pack_dir, include_drafts?) do
        {:ok, ticket} -> {:cont, {:ok, [ticket | tickets]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, tickets} -> {:ok, Enum.reverse(tickets)}
      :error -> :error
    end
  end

  defp tickets(_list, _pack_dir, _include_drafts?), do: :error

  defp ticket(%{"id" => id} = attributes, pack_dir, include_drafts?) when is_binary(id) and id != "" do
    with {:ok, number} <- ticket_number(attributes),
         document_path <- ticket_document_path(attributes),
         true <- safe_document_path?(document_path) do
      {:ok,
       %{
         id: id,
         title: Map.get(attributes, "title", id),
         lane: ticket_lane(attributes),
         phase: ticket_phase(attributes),
         complexity: ticket_complexity(attributes),
         number: number,
         node_id: ticket_node_id(attributes),
         depends_on: List.wrap(Map.get(attributes, "depends_on", [])),
         document_url: nil,
         document_path: document_path,
         draft_body: if(include_drafts? and is_nil(number), do: draft_body(document_path, pack_dir)),
         icon: Map.get(attributes, "icon")
       }}
    else
      _invalid -> :error
    end
  end

  defp ticket(_attributes, _pack_dir, _include_drafts?), do: :error

  defp ticket_document_path(attributes), do: Map.get(attributes, "doc") || Map.get(attributes, "document")

  defp ticket_lane(attributes), do: to_string(Map.get(attributes, "lane") || Map.get(attributes, "workstream") || "unassigned")

  defp ticket_phase(attributes), do: Map.get(attributes, "phase") || Map.get(attributes, "phase_hint") || 0

  defp ticket_complexity(attributes), do: Map.get(attributes, "complexity") || Map.get(attributes, "complexity_points")

  defp ticket_node_id(attributes), do: get_in(attributes, ["github", "node_id"])

  defp safe_document_path?(path) when is_binary(path) and byte_size(path) in 1..512 do
    Path.type(path) == :relative and
      String.starts_with?(path, "tickets/") and
      not Enum.member?(Path.split(path), "..")
  end

  defp safe_document_path?(_path), do: false

  defp draft_body(path, pack_dir) when is_binary(path) do
    pack_dir = Path.expand(pack_dir)
    document = Path.expand(path, pack_dir)

    if document_inside_pack?(document, pack_dir) do
      case File.read(document) do
        {:ok, body} when byte_size(body) in 1..64_000 -> body
        _missing_or_invalid -> nil
      end
    end
  end

  defp draft_body(_path, _pack_dir), do: nil

  defp document_inside_pack?(document, pack_dir) do
    document == pack_dir or String.starts_with?(document, pack_dir <> "/")
  end

  defp status(path) do
    path
    |> PackPaths.status_path()
    |> File.read()
    |> case do
      {:ok, body} -> Jason.decode(body)
      _missing -> {:error, :missing}
    end
    |> case do
      {:ok, map} when is_map(map) -> map
      _invalid -> %{}
    end
  end

  defp status_completed?(%{"state" => state}) when state in ["completed", "COMPLETE", "complete"], do: true
  defp status_completed?(%{"completed" => true}), do: true
  defp status_completed?(_status), do: false

  defp status_completed_at(%{"completed_at" => value}) when is_binary(value), do: value
  defp status_completed_at(_status), do: nil

  defp status_lifecycle(%TrackerIdentity{identifier: identifier}, %{status: status}) do
    state =
      status
      |> status_members()
      |> Map.get(identifier)
      |> case do
        %{"lifecycle" => lifecycle} -> lifecycle
        %{"state" => value} -> value
        value when is_binary(value) -> value
        _missing -> nil
      end

    case state do
      value when value in ["completed", "COMPLETE", "complete"] -> :completed
      value when value in ["cancelled", "canceled", "CANCELLED", "CANCELED"] -> :cancelled
      value when value in ["open", "OPEN"] -> :open
      _unknown -> nil
    end
  end

  defp status_lifecycle(_identity, _pack), do: nil

  defp status_members(%{"members" => members}) when is_map(members), do: members
  defp status_members(_status), do: %{}

  defp ticket_number(%{"ticket" => ticket}) when is_integer(ticket) and ticket > 0, do: {:ok, ticket}
  defp ticket_number(%{"ticket" => nil}), do: {:ok, nil}
  defp ticket_number(%{"github" => %{"number" => ticket}}) when is_integer(ticket) and ticket > 0, do: {:ok, ticket}
  defp ticket_number(_attributes), do: :error

  @default_icons ["bolt", "cube", "sparkles", "server-stack", "rectangle-group"]

  defp assign_default_icons(packs) do
    {packs, _used_icons} =
      Enum.map_reduce(packs, MapSet.new(), fn pack, used_icons ->
        if pack.icon_explicit? do
          {pack, MapSet.put(used_icons, pack.icon)}
        else
          icon = unique_default_icon(pack.build_order_id, used_icons)
          {%{pack | icon: icon}, MapSet.put(used_icons, icon)}
        end
      end)

    packs
  end

  defp pack_icon(%{"icon" => icon}) when is_binary(icon) and icon != "", do: icon

  defp pack_icon(json) do
    unique_default_icon(Map.get(json, "build_order_id", "planning"), MapSet.new())
  end

  defp unique_default_icon(build_order_id, used_icons) do
    offset = :erlang.phash2(build_order_id, length(@default_icons))

    candidates =
      @default_icons
      |> Stream.cycle()
      |> Stream.drop(offset)
      |> Enum.take(length(@default_icons))

    Enum.find(candidates, &(not MapSet.member?(used_icons, &1))) || hd(candidates)
  end

  defp pack_before?(left, right) do
    cond do
      left.completed != right.completed -> not left.completed
      left.completed and left.completed_at != right.completed_at -> (left.completed_at || "") > (right.completed_at || "")
      true -> left.title < right.title
    end
  end

  defp configured_repository do
    Config.repo()
  rescue
    _error -> nil
  end

  defp absolute_path(path), do: if(Path.type(path) == :absolute, do: path, else: Application.app_dir(:aiur, path))
end
