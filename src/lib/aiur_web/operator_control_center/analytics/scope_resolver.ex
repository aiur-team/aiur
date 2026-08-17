defmodule AiurWeb.OperatorControlCenter.Analytics.ScopeResolver do
  @moduledoc """
  Resolves the Analytics page's optional Build Order scope without a LiveView.

  Both the route and the CLI use this boundary so a selected Build Order always
  derives its members from the graph projection rather than reconstructing them
  from labels or tracker reads.

  ## The two callers want different things from a miss

  The Analytics *page* must never fetch. An operator opening `/analytics` — or
  leaving it open, or reloading it — has stated no need beyond looking, and a
  page that fetches makes API cost scale with how many people are watching.

  The `aiur analytics` *CLI* is the opposite: it is a one-shot command that
  exists to answer a question now, and a cold graph it declines to fetch is an
  empty report. That is a real need, and a real need may spend.

  So the fetch is a caller's explicit choice via `:fetch`, defaulting to
  `false`. The default is the safe direction: a caller who forgets reads what
  is there and reports `:unavailable`, rather than silently reintroducing the
  per-viewer graph fetch this boundary exists to remove.
  """

  alias Aiur.BuildOrder.{Catalog, Member, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.RunTelemetry
  alias Aiur.TrackerIdentity
  alias Aiur.Usage.GroupedScopes.Scope
  alias AiurWeb.BuildOrder.Runtime

  @type resolved_scope ::
          :session
          | :unavailable
          | %{
              kind: :build_order,
              root_number: String.t(),
              tickets: MapSet.t(String.t()),
              total: non_neg_integer(),
              usage_scope: Scope.t()
            }

  @doc """
  Resolves the Build Order scope named by `root_number`.

  Pass `fetch: true` only from a consumer that genuinely needs the graph to
  proceed. Anything rendering a view must leave it unset.
  """
  @spec resolve(String.t() | nil, keyword()) :: resolved_scope()
  def resolve(root_number, opts \\ [])
  def resolve(nil, _opts), do: :session

  def resolve(root_number, opts) when is_binary(root_number) do
    source = Keyword.get(opts, :data_source, Application.get_env(:aiur, :build_order_data_source, AiurWeb.BuildOrder.DataSource))
    read = if Keyword.get(opts, :fetch, false), do: :demand, else: :selected

    with %Snapshot{data: %Catalog{entries: entries}} <- Runtime.safe_source_call(source, :catalog, [], nil),
         %RootSummary{identity: %TrackerIdentity{} = identity} <-
           Enum.find(entries, &(TrackerIdentity.joinable?(&1.identity) and &1.identity.identifier == root_number)),
         {:ok, %Snapshot{data: %SelectedRoot{members: members}}} <-
           Runtime.safe_source_call(source, read, [identity], {:error, :unavailable}),
         identities when identities != [] <- member_identities(members),
         {:ok, usage_scope} <- Scope.intersection(RunTelemetry.boot_id(), identities) do
      %{
        kind: :build_order,
        root_number: root_number,
        tickets: MapSet.new(identities, & &1.identifier),
        total: length(members),
        usage_scope: usage_scope
      }
    else
      _other -> :unavailable
    end
  end

  def resolve(_root_number, _opts), do: :unavailable

  @spec telemetry_opts(resolved_scope()) :: keyword()
  def telemetry_opts(%{kind: :build_order, tickets: tickets, total: total}), do: [tickets: MapSet.to_list(tickets), scope_total: total]
  def telemetry_opts(:session), do: []
  def telemetry_opts(:unavailable), do: [tickets: []]

  @spec usage_scope(resolved_scope()) :: {:ok, Scope.t()} | {:error, :unavailable}
  def usage_scope(%{kind: :build_order, usage_scope: scope}), do: {:ok, scope}
  def usage_scope(:session), do: Scope.this_run(RunTelemetry.boot_id())
  def usage_scope(:unavailable), do: {:error, :unavailable}

  defp member_identities(members) do
    Enum.flat_map(members, fn
      %Member{identity: %TrackerIdentity{} = identity} -> if(TrackerIdentity.joinable?(identity), do: [identity], else: [])
      _other -> []
    end)
  end
end
