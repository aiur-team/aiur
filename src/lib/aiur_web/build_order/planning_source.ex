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
  keyed by their numeric ticket id; the pack is marked `planning?: true` so the
  view renders them as planned (no live progress) rather than as live issues.

  This is read-only demo/planning tooling — it never writes to GitHub. Point it
  at a pack with `:build_order_planning_pack` (an app-relative priv path).
  """

  @behaviour AiurWeb.BuildOrder.DataSource

  alias Aiur.BuildOrder.{Catalog, Dependency, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity

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
    case load_packs() do
      [] ->
        nil

      packs ->
        %Snapshot{
          scope: :catalog,
          repository: hd(packs).repository,
          generation: @generation,
          authority_epoch: @epoch,
          data: Catalog.new(Enum.map(packs, &root_summary/1), health()),
          health: health()
        }
    end
  end

  # --- selected root ---------------------------------------------------------

  @impl true
  def demand(%TrackerIdentity{} = identity), do: {:ok, selected_snapshot(identity)}

  @impl true
  def selected(%TrackerIdentity{} = identity), do: {:ok, selected_snapshot(identity)}

  defp selected_snapshot(identity) do
    case Enum.find(load_packs(), &pack_root?(&1, identity)) do
      %{} = pack ->
        %Snapshot{
          scope: {:selected, identity},
          repository: pack.repository,
          generation: @generation,
          authority_epoch: @epoch,
          data: SelectedRoot.new(root_summary(pack), members(pack), health(), planning?: not pack.completed),
          health: health()
        }

      nil ->
        %Snapshot{
          scope: {:selected, identity},
          repository: {"unknown", "unknown"},
          generation: @generation,
          authority_epoch: @epoch,
          data: nil,
          health: health()
        }
    end
  end

  # A selected root identity carries the pack's repository and root number.
  defp pack_root?(pack, %TrackerIdentity{owner: owner, repository: repo, identifier: number}),
    do: pack.repository == {owner, repo} and to_string(pack.root_number) == to_string(number)

  # --- runtime sources / context (planning mode: nothing live) ---------------

  @impl true
  def load_sources, do: %{execution: :unavailable, activity: :unavailable, adhoc: :unavailable}

  @impl true
  def load_context(_identity), do: %{detail: :unavailable, history: :unavailable}

  # --- subscriptions: static source, nothing to subscribe to -----------------

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
  def subscribe_sources, do: :ok
  @impl true
  def subscribe_context(_identity), do: :ok
  @impl true
  def unsubscribe_context(_identity), do: :ok

  # --- pack -> structs -------------------------------------------------------

  defp root_summary(pack) do
    identity = root_identity(pack)

    RootSummary.new(%{
      identity: identity,
      title: pack.title,
      state: :open,
      url: issue_url(identity),
      member_count: length(pack.tickets),
      epic_count: pack.tickets |> Enum.map(& &1.lane) |> Enum.uniq() |> length(),
      phase_count: pack.tickets |> Enum.map(& &1.phase) |> Enum.uniq() |> length(),
      progress: progress_percent(pack)
    })
  end

  # A pack flagged `completed` has shipped every ticket → 100%. Otherwise a
  # planning pack is pre-ticket, so completion is 0% (the merged fraction, which
  # stays correct once tickets materialize).
  defp progress_percent(%{completed: true}), do: 100
  defp progress_percent(%{tickets: []}), do: 0

  defp progress_percent(%{tickets: tickets}) do
    merged = Enum.count(tickets, &match?(%{github: %{"merged" => true}}, &1))
    round(merged / length(tickets) * 100)
  end

  defp members(pack) do
    ids = MapSet.new(pack.tickets, & &1.id)
    {state, reason} = if pack.completed, do: {"CLOSED", "COMPLETED"}, else: {"OPEN", nil}

    Enum.map(pack.tickets, fn ticket ->
      identity = ticket_identity(pack, ticket)

      dependencies =
        ticket.depends_on
        |> Enum.filter(&MapSet.member?(ids, &1))
        |> Enum.map(fn dep_id ->
          Dependency.new(identity, ticket_identity(pack, %{id: dep_id}), nil, :blocked_by)
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

  defp root_identity(pack), do: identity!(pack.repository, pack.root_number, "BO_ROOT")

  defp ticket_identity(pack, ticket) do
    number = ticket_number(pack, ticket)
    identity!(pack.repository, number, "PLAN_#{ticket.id}")
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

  defp health, do: ProviderHealth.new(@generation, :healthy, true, observed_at: DateTime.utc_now())

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
      nil -> Application.get_env(:aiur, :build_order_planning_packs, @default_packs)
      path -> [path]
    end
  end

  defp load_pack(path) do
    absolute = if Path.type(path) == :absolute, do: path, else: Application.app_dir(:aiur, path)

    with {:ok, body} <- File.read(absolute),
         {:ok, json} <- Jason.decode(body),
         {:ok, repository} <- repository(json) do
      tickets = tickets(Map.get(json, "tickets", []))

      {:ok,
       %{
         repository: repository,
         build_order_id: Map.get(json, "build_order_id", "planning"),
         title: Map.get(json, "title", "Planning build order"),
         root_number: Map.get(json, "root_number", @root_number),
         completed: Map.get(json, "completed", false) == true,
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

  defp repository(json) do
    case String.split(to_string(Map.get(json, "repository", "")), "/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" -> {:ok, {owner, repo}}
      _other -> :error
    end
  end

  defp tickets(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"id" => id} = ticket when is_binary(id) ->
        [
          %{
            id: id,
            title: Map.get(ticket, "title", id),
            lane: to_string(Map.get(ticket, "lane", "unassigned")),
            phase: Map.get(ticket, "phase", 0),
            complexity: Map.get(ticket, "complexity"),
            number: Map.get(ticket, "number"),
            depends_on: List.wrap(Map.get(ticket, "depends_on", [])),
            document_url: Map.get(ticket, "document_url")
          }
        ]

      _other ->
        []
    end)
  end

  defp tickets(_list), do: []
end
