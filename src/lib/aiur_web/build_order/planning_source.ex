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
  keyed by their numeric ticket id. Packs with materialized GitHub mappings are
  hydrated from the daemon's current-run membership projection; pre-ticket packs
  remain planning-only.

  This is read-only demo/planning tooling — it never writes to GitHub. Point it
  at a pack with `:build_order_planning_pack` (an app-relative priv path).
  """

  @behaviour AiurWeb.BuildOrder.DataSource

  require Logger

  alias Aiur.BuildOrder.{Catalog, Dependency, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.CurrentRunMembership
  alias Aiur.GitHub.Config
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.RepoBase
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

    %Snapshot{
      scope: :catalog,
      repository: catalog_repository(packs),
      generation: generation(membership),
      authority_epoch: @epoch,
      data: Catalog.new(Enum.map(packs, &root_summary(&1, membership)), health(membership), search_paths: catalog_search_paths()),
      health: health(membership)
    }
  end

  # --- selected root ---------------------------------------------------------

  @impl true
  def demand(%TrackerIdentity{} = identity), do: {:ok, selected_snapshot(identity)}

  @impl true
  def selected(%TrackerIdentity{} = identity), do: {:ok, selected_snapshot(identity)}

  defp selected_snapshot(identity) do
    membership = membership_snapshot()

    case Enum.find(load_packs(include_drafts?: true), &pack_root?(&1, identity)) do
      %{} = pack ->
        %Snapshot{
          scope: {:selected, identity},
          repository: pack.repository,
          generation: generation(membership),
          authority_epoch: @epoch,
          data: SelectedRoot.new(root_summary(pack, membership), members(pack, membership), health(membership), planning?: not (pack.materialized? or pack.completed)),
          health: health(membership)
        }

      nil ->
        %Snapshot{
          scope: {:selected, identity},
          repository: {"unknown", "unknown"},
          generation: generation(membership),
          authority_epoch: @epoch,
          data: nil,
          health: health(membership)
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
    with :ok <- DataSource.subscribe_sources(), do: CurrentRunMembership.subscribe()
  end

  @impl true
  def subscribe_context(_identity), do: :ok
  @impl true
  def unsubscribe_context(_identity), do: :ok

  # --- pack -> structs -------------------------------------------------------

  defp root_summary(pack, membership) do
    identity = root_identity(pack)

    RootSummary.new(%{
      identity: identity,
      title: pack.title,
      icon: pack.icon,
      state: :open,
      url: issue_url(identity),
      member_count: length(pack.tickets),
      epic_count: pack.tickets |> Enum.map(& &1.lane) |> Enum.uniq() |> length(),
      phase_count: pack.tickets |> Enum.map(& &1.phase) |> Enum.uniq() |> length(),
      progress: progress_percent(pack, membership),
      completed?: pack.completed
    })
  end

  defp progress_percent(%{tickets: []}, _membership), do: 0

  defp progress_percent(%{tickets: tickets} = pack, membership) do
    if Enum.all?(tickets, &completion_known?(&1, pack, membership)) do
      completed = Enum.count(tickets, &completed?(&1, pack, membership))
      round(completed / length(tickets) * 100)
    end
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

  defp health(%{health: :healthy, freshness: %{status: :fresh}} = membership) do
    ProviderHealth.new(generation(membership), :healthy, true, observed_at: DateTime.utc_now())
  end

  defp health(%{health: :healthy, freshness: %{status: status}} = membership)
       when status in [:stale, :unknown] do
    ProviderHealth.new(generation(membership), :stale, false, observed_at: DateTime.utc_now(), failure: :membership_stale)
  end

  defp health(%{health: :healthy, freshness: %{status: :unavailable}} = membership) do
    ProviderHealth.new(generation(membership), :unavailable, false,
      observed_at: DateTime.utc_now(),
      failure: :membership_unavailable
    )
  end

  defp health(%{health: {:degraded, _reason}} = membership) do
    ProviderHealth.new(generation(membership), :stale, false, observed_at: DateTime.utc_now(), failure: :membership_stale)
  end

  defp health(%{health: {:unavailable, _reason}} = membership) do
    ProviderHealth.new(generation(membership), :unavailable, false,
      observed_at: DateTime.utc_now(),
      failure: :membership_unavailable
    )
  end

  defp health(%{health: :unavailable} = membership) do
    ProviderHealth.new(generation(membership), :unavailable, false,
      observed_at: DateTime.utc_now(),
      failure: :membership_unavailable
    )
  end

  defp health(membership), do: ProviderHealth.new(generation(membership), :healthy, true, observed_at: DateTime.utc_now())

  defp generation(%{generation: generation}) when is_integer(generation) and generation >= 0, do: @generation + generation
  defp generation(_membership), do: @generation

  defp lifecycle(%{number: nil}, _identity, _pack, _membership), do: {"OPEN", nil}

  defp lifecycle(_ticket, identity, pack, membership) do
    case membership_lifecycle(identity, membership) || status_lifecycle(identity, pack) do
      :completed -> {"CLOSED", "COMPLETED"}
      :cancelled -> {"CLOSED", "NOT_PLANNED"}
      _other when pack.completed -> {"CLOSED", "COMPLETED"}
      _other -> {"OPEN", nil}
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
    membership_member?(member_identity(pack, ticket, membership), membership) or
      case status_lifecycle(member_identity(pack, ticket, membership), pack) do
        state when state in [:completed, :cancelled, :open] -> true
        _unknown -> false
      end
  end

  defp membership_member?(identity, %{members: members}) when is_list(members), do: not is_nil(membership_member(identity, members))
  defp membership_member?(_identity, _membership), do: false

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

  # Runtime packs are re-discovered from the configured repository's state node.
  # Environment directories remain an explicit test/development override.
  defp discovered_packs do
    (tag_paths(workspace_pack_paths(), :workspace) ++ tag_paths(state_pack_paths(), :state) ++ tag_paths(override_pack_paths(), :override))
    |> Enum.uniq()
  end

  defp tag_paths(paths, source), do: Enum.map(paths, &{source, &1})

  defp workspace_pack_paths do
    workspace_pack_directory()
    |> Path.join("*.json")
    |> Path.wildcard()
  end

  defp override_pack_paths do
    case System.get_env("AIUR_BUILD_ORDER_DIRS") do
      dirs when is_binary(dirs) and dirs != "" ->
        dirs
        |> String.split(":", trim: true)
        |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.json")))

      _missing ->
        []
    end
  end

  defp state_pack_paths do
    case configured_repository() do
      repository when is_binary(repository) and repository != "" ->
        repository
        |> then(&RepoBase.builds_path("https://github.com/#{&1}.git"))
        |> Path.join("*/build-order.json")
        |> Path.wildcard()

      _missing ->
        []
    end
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
          _missing -> discovery_directories()
        end

      path ->
        [Path.dirname(absolute_path(path))]
    end
  end

  defp discovery_directories do
    [workspace_pack_directory(), state_pack_directory() | override_pack_directories()]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp workspace_pack_directory, do: Path.join([File.cwd!(), ".aiur", "build_orders"])

  defp state_pack_directory do
    case configured_repository() do
      repository when is_binary(repository) and repository != "" ->
        RepoBase.builds_path("https://github.com/#{repository}.git")

      _missing ->
        nil
    end
  end

  defp override_pack_directories do
    case System.get_env("AIUR_BUILD_ORDER_DIRS") do
      dirs when is_binary(dirs) and dirs != "" -> String.split(dirs, ":", trim: true)
      _missing -> []
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
         completed: Map.get(json, "completed", false) == true or status_completed?(status),
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
      case Enum.find(selected, &same_catalog_pack?(&1, pack)) do
        nil ->
          [pack | selected]

        chosen ->
          Logger.warning(
            "build order catalog discarded #{duplicate_kind(chosen, pack)} #{inspect(pack.build_order_id)} from #{pack.source} (#{pack.path}); " <>
              "source precedence #{@pack_source_precedence_description} selected #{chosen.source} (#{chosen.path})"
          )

          selected
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
    |> Path.dirname()
    |> Path.join("status.json")
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
      |> Map.get("members", %{})
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
