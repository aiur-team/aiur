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
  @default_pack "priv/build_orders/croptracker-demo.json"

  # --- catalog ---------------------------------------------------------------

  @impl true
  def catalog do
    case load_pack() do
      {:ok, pack} ->
        %Snapshot{
          scope: :catalog,
          repository: pack.repository,
          generation: @generation,
          authority_epoch: @epoch,
          data: Catalog.new([root_summary(pack)], health()),
          health: health()
        }

      :error ->
        nil
    end
  end

  # --- selected root ---------------------------------------------------------

  @impl true
  def demand(%TrackerIdentity{} = identity), do: {:ok, selected_snapshot(identity)}

  @impl true
  def selected(%TrackerIdentity{} = identity), do: {:ok, selected_snapshot(identity)}

  defp selected_snapshot(identity) do
    case load_pack() do
      {:ok, pack} ->
        %Snapshot{
          scope: {:selected, identity},
          repository: pack.repository,
          generation: @generation,
          authority_epoch: @epoch,
          data: SelectedRoot.new(root_summary(pack), members(pack), health(), planning?: true),
          health: health()
        }

      :error ->
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
    RootSummary.new(%{identity: identity, title: pack.title, state: :open, url: issue_url(identity)})
  end

  defp members(pack) do
    ids = MapSet.new(pack.tickets, & &1.id)

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
        state: "OPEN",
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

  defp root_identity(pack), do: identity!(pack.repository, @root_number, "BO_ROOT")

  defp ticket_identity(pack, ticket) do
    number = ticket_number(ticket.id)
    identity!(pack.repository, number, "PLAN_#{ticket.id}")
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

  defp load_pack do
    path = Application.get_env(:aiur, :build_order_planning_pack, @default_pack)
    absolute = if Path.type(path) == :absolute, do: path, else: Application.app_dir(:aiur, path)

    with {:ok, body} <- File.read(absolute),
         {:ok, json} <- Jason.decode(body),
         {:ok, repository} <- repository(json) do
      {:ok,
       %{
         repository: repository,
         build_order_id: Map.get(json, "build_order_id", "planning"),
         title: Map.get(json, "title", "Planning build order"),
         tickets: tickets(Map.get(json, "tickets", []))
       }}
    else
      _error -> :error
    end
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
