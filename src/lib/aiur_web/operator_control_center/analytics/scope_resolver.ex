defmodule AiurWeb.OperatorControlCenter.Analytics.ScopeResolver do
  @moduledoc """
  Resolves the Analytics page's optional Build Order scope without a LiveView.

  Both the route and the CLI use this boundary so a selected Build Order always
  derives its members from the graph projection rather than reconstructing them
  from labels or tracker reads.
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

  @spec resolve(String.t() | nil, keyword()) :: resolved_scope()
  def resolve(root_number, opts \\ [])
  def resolve(nil, _opts), do: :session

  def resolve(root_number, opts) when is_binary(root_number) do
    source = Keyword.get(opts, :data_source, Application.get_env(:aiur, :build_order_data_source, AiurWeb.BuildOrder.DataSource))

    with %Snapshot{data: %Catalog{entries: entries}} <- Runtime.safe_source_call(source, :catalog, [], nil),
         %RootSummary{identity: %TrackerIdentity{} = identity} <-
           Enum.find(entries, &(TrackerIdentity.joinable?(&1.identity) and &1.identity.identifier == root_number)),
         {:ok, %Snapshot{data: %SelectedRoot{members: members}}} <-
           Runtime.safe_source_call(source, :demand, [identity], {:error, :unavailable}),
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
  def usage_scope(scope), do: usage_scope(scope, RunTelemetry.boot_id())

  @spec usage_scope(resolved_scope(), String.t() | nil) :: {:ok, Scope.t()} | {:error, :unavailable | :invalid_run_identity}
  def usage_scope(%{kind: :build_order, usage_scope: %Scope{} = scope}, run_id)
      when is_binary(run_id) and run_id != "",
      do: {:ok, %Scope{scope | run_id: run_id}}

  def usage_scope(:session, run_id), do: Scope.this_run(run_id)
  def usage_scope(_scope, _run_id), do: {:error, :unavailable}

  defp member_identities(members) do
    Enum.flat_map(members, fn
      %Member{identity: %TrackerIdentity{} = identity} -> if(TrackerIdentity.joinable?(identity), do: [identity], else: [])
      _other -> []
    end)
  end
end
