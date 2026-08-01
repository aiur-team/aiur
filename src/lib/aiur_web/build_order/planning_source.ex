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

  alias Aiur.BuildOrder.{Catalog, Dependency, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.CurrentRunMembership
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.DataSource

  @epoch 1
  @generation 1
  @root_number 9000

  # Default catalog: the permanent aiur build-order plan (kept in the repo) plus
  # the CropTracker demo pack. A single `:build_order_planning_pack` override
  # still selects exactly one pack for tests and focused demos.
  @default_packs [
    "priv/build_orders/aiur-build-order.json",
    "priv/build_orders/croptracker-demo.json"
  ]

  # --- catalog ---------------------------------------------------------------

  @impl true
  def catalog do
    membership = membership_snapshot()

    case load_packs() do
      [] ->
        nil

      packs ->
        %Snapshot{
          scope: :catalog,
          repository: hd(packs).repository,
          generation: generation(membership),
          authority_epoch: @epoch,
          data: Catalog.new(Enum.map(packs, &root_summary(&1, membership)), health(membership)),
          health: health(membership)
        }
    end
  end

  # --- selected root ---------------------------------------------------------

  @impl true
  def demand(%TrackerIdentity{} = identity), do: {:ok, selected_snapshot(identity)}

  @impl true
  def selected(%TrackerIdentity{} = identity), do: {:ok, selected_snapshot(identity)}

  defp selected_snapshot(identity) do
    membership = membership_snapshot()

    case Enum.find(load_packs(), &pack_root?(&1, identity)) do
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
      state: :open,
      url: issue_url(identity),
      member_count: length(pack.tickets),
      epic_count: pack.tickets |> Enum.map(& &1.lane) |> Enum.uniq() |> length(),
      phase_count: pack.tickets |> Enum.map(& &1.phase) |> Enum.uniq() |> length(),
      progress: progress_percent(pack, membership)
    })
  end

  defp progress_percent(%{tickets: []}, _membership), do: 0

  defp progress_percent(%{tickets: tickets} = pack, membership) do
    completed = Enum.count(tickets, &completed?(&1, pack, membership))
    round(completed / length(tickets) * 100)
  end

  defp members(pack, membership) do
    ids = MapSet.new(pack.tickets, & &1.id)

    identities =
      Map.new(pack.tickets, fn ticket ->
        {ticket.id, member_identity(pack, ticket, membership)}
      end)

    Enum.map(pack.tickets, fn ticket ->
      identity = Map.fetch!(identities, ticket.id)
      {state, reason} = lifecycle(identity, pack, membership)

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
        state: state,
        state_reason: reason,
        labels: labels(ticket),
        dependencies: dependencies
      })
    end)
  end

  defp issue_url(%TrackerIdentity{owner: owner, repository: repo, identifier: number}),
    do: "https://github.com/#{owner}/#{repo}/issues/#{number}"

  defp labels(ticket) do
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
      _missing -> ticket_number(id)
    end
  end

  # CT-101 -> 101. Falls back to a stable hash for non-numeric ids.
  defp ticket_number(id) do
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

  defp lifecycle(identity, pack, membership) do
    case membership_lifecycle(identity, membership) do
      :completed -> {"CLOSED", "COMPLETED"}
      :cancelled -> {"CLOSED", "NOT_PLANNED"}
      _other when pack.completed -> {"CLOSED", "COMPLETED"}
      _other -> {"OPEN", nil}
    end
  end

  defp completed?(ticket, pack, membership) do
    match?(
      {"CLOSED", "COMPLETED"},
      lifecycle(member_identity(pack, ticket, membership), pack, membership)
    )
  end

  defp membership_lifecycle(identity, %{members: members}) when is_list(members) do
    membership_member(identity, members)
    |> then(&Map.get(&1 || %{}, :lifecycle))
  end

  defp membership_lifecycle(_identity, _membership), do: nil

  defp member_identity(pack, ticket, %{members: members}) when is_list(members) do
    identity = ticket_identity(pack, ticket)

    case membership_member(identity, members) do
      %{identity: %TrackerIdentity{} = member_identity} -> member_identity
      _member -> identity
    end
  end

  defp member_identity(pack, ticket, _membership), do: ticket_identity(pack, ticket)

  defp membership_member(identity, members), do: Enum.find(members, &same_issue?(&1, identity))

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
    Application.get_env(:aiur, :build_order_planning_membership_snapshot, &CurrentRunMembership.snapshot/0).()
  rescue
    _error -> %{health: :unavailable}
  catch
    _kind, _reason -> %{health: :unavailable}
  end

  # --- pack loading ----------------------------------------------------------

  defp load_packs do
    pack_paths()
    |> Enum.map(&load_pack/1)
    |> Enum.flat_map(fn
      {:ok, pack} -> [pack]
      :error -> []
    end)
  end

  defp pack_paths do
    case Application.get_env(:aiur, :build_order_planning_pack) do
      nil -> Application.get_env(:aiur, :build_order_planning_packs, Enum.uniq_by(discovered_packs() ++ @default_packs, &Path.basename/1))
      path -> [path]
    end
  end

  # Runtime packs are re-discovered for every request. The daemon's checkout is
  # first so a run-local pack shadows an identically named global pack.
  defp discovered_packs do
    discovery_dirs()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.json")))
    |> Enum.uniq_by(&Path.basename/1)
  end

  defp discovery_dirs do
    case System.get_env("AIUR_BUILD_ORDER_DIRS") do
      dirs when is_binary(dirs) and dirs != "" -> String.split(dirs, ":", trim: true)
      _missing -> [Path.join([File.cwd!(), ".aiur", "build_orders"]), global_build_order_dir()]
    end
  end

  defp global_build_order_dir do
    root = System.get_env("AIUR_BG_STATE_DIR") || System.get_env("XDG_CONFIG_HOME") || Path.expand("~/.config")
    Path.join(root, "aiur/build_orders")
  end

  defp load_pack(path) do
    absolute = if Path.type(path) == :absolute, do: path, else: Application.app_dir(:aiur, path)

    with {:ok, body} <- File.read(absolute),
         {:ok, json} <- Jason.decode(body),
         {:ok, repository} <- repository(json) do
      mapping = issue_mapping(json)
      tickets = tickets(Map.get(json, "tickets", []), mapping)

      {:ok,
       %{
         repository: repository,
         build_order_id: Map.get(json, "build_order_id", "planning"),
         title: Map.get(json, "title", "Planning build order"),
         root_number: root_number(json, mapping),
         root_node_id: root_node_id(json, mapping),
         completed: Map.get(json, "completed", false) == true,
         materialized?: Enum.any?(tickets, &is_integer(&1.number)),
         tickets: tickets,
         numbers: ticket_numbers(tickets)
       }}
    else
      _error -> :error
    end
  end

  defp ticket_numbers(tickets) do
    for %{id: id, number: number} <- tickets, is_integer(number), into: %{}, do: {id, number}
  end

  defp root_number(json, mapping) do
    Map.get(json, "root_number") ||
      get_in(json, ["github_root", "number"]) ||
      Map.get(mapping, "root_number") ||
      mapping_number(Map.get(mapping, "root")) ||
      mapping_number(Map.get(mapping, Map.get(json, "build_order_id"))) || @root_number
  end

  defp root_node_id(json, mapping) do
    get_in(json, ["github_root", "node_id"]) ||
      mapping_node_id(Map.get(mapping, "root")) ||
      mapping_node_id(Map.get(mapping, Map.get(json, "build_order_id")))
  end

  defp issue_mapping(json) do
    Map.get(json, "issue_mapping") || get_in(json, ["github_reconciliation", "issue_mappings"]) || %{}
  end

  defp mapping_number(number) when is_integer(number), do: number
  defp mapping_number(%{"number" => number}) when is_integer(number), do: number
  defp mapping_number(_mapping), do: nil

  defp mapping_node_id(%{"node_id" => node_id}) when is_binary(node_id) and node_id != "", do: node_id
  defp mapping_node_id(_mapping), do: nil

  defp repository(json) do
    case String.split(to_string(Map.get(json, "repository", "")), "/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" -> {:ok, {owner, repo}}
      _other -> :error
    end
  end

  defp tickets(list, mapping) when is_list(list) do
    Enum.flat_map(list, &ticket(&1, mapping))
  end

  defp tickets(_list, _mapping), do: []

  defp ticket(%{"id" => id} = attributes, mapping) when is_binary(id) do
    github = Map.get(attributes, "github")
    mapped = Map.get(mapping, id)

    [
      %{
        id: id,
        title: Map.get(attributes, "title", id),
        lane: to_string(first_value([Map.get(attributes, "lane"), Map.get(attributes, "workstream"), "unassigned"])),
        phase: first_value([Map.get(attributes, "phase"), Map.get(attributes, "phase_hint"), 0]),
        complexity: first_value([Map.get(attributes, "complexity"), Map.get(attributes, "complexity_points")]),
        number: first_value([Map.get(attributes, "number"), Map.get(attributes, "github_number"), mapping_number(github), mapping_number(mapped)]),
        node_id: first_value([Map.get(attributes, "github_node_id"), mapping_node_id(github), mapping_node_id(mapped)]),
        depends_on: List.wrap(Map.get(attributes, "depends_on", [])),
        document_url: first_value([Map.get(attributes, "document_url"), get_in(attributes, ["github", "url"])])
      }
    ]
  end

  defp ticket(_attributes, _mapping), do: []

  defp first_value(values), do: Enum.find(values, & &1)
end
