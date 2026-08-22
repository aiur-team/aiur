defmodule AiurWeb.BuildOrder.DataSource do
  @moduledoc """
  Read-only boundary between Build Order LiveView orchestration and supervised
  projections/caches.

  Refresh cadence and provider I/O remain owned by the underlying services.
  This adapter deliberately exposes no provider or mutation callback.
  """

  alias Aiur.AgentPubSub
  alias Aiur.BuildOrder.{AdHocSource, GraphProjection, TicketDetailCoordinator, TicketHistoryProvider}
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.TicketActivity
  alias Aiur.TrackerIdentity

  @callback catalog() :: term()
  @callback subscribe_catalog() :: :ok | {:error, term()}
  @callback unsubscribe_catalog(TrackerIdentity.repository()) :: :ok | {:error, term()}
  @callback subscribe_selected(TrackerIdentity.t()) :: :ok | {:error, term()}
  @callback unsubscribe_selected(TrackerIdentity.t()) :: :ok | {:error, term()}
  @callback selected(TrackerIdentity.t()) :: term()
  @callback demand(TrackerIdentity.t()) :: term()
  @callback refresh(TrackerIdentity.t()) :: term()
  @callback release(TrackerIdentity.t()) :: term()
  @callback subscribe_sources() :: :ok | {:error, term()}
  @callback load_runtime_sources() :: %{activity: term(), execution: term()}
  @callback load_sources() :: %{activity: term(), execution: term(), adhoc: term()}
  @callback subscribe_context(TrackerIdentity.t()) :: :ok | {:error, term()}
  @callback unsubscribe_context(TrackerIdentity.t()) :: :ok | {:error, term()}
  @callback load_context(TrackerIdentity.t()) :: %{detail: term(), history: term()}

  @spec catalog(keyword()) :: term()
  def catalog(opts \\ []), do: call(dependency(opts, :graph_projection, GraphProjection), :catalog, [])

  @spec subscribe_catalog(keyword()) :: :ok | {:error, term()}
  def subscribe_catalog(opts \\ []),
    do: call(dependency(opts, :graph_projection, GraphProjection), :subscribe_catalog, [])

  @spec unsubscribe_catalog(TrackerIdentity.repository(), keyword()) :: :ok | {:error, term()}
  def unsubscribe_catalog(repository, opts \\ []) do
    projection = dependency(opts, :graph_projection, GraphProjection)
    unsubscribe(opts).(call(projection, :catalog_topic, [repository]))
  end

  @spec subscribe_selected(TrackerIdentity.t(), keyword()) :: :ok | {:error, term()}
  def subscribe_selected(identity, opts \\ []),
    do: call(dependency(opts, :graph_projection, GraphProjection), :subscribe_selected, [identity])

  @spec unsubscribe_selected(TrackerIdentity.t(), keyword()) :: :ok | {:error, term()}
  def unsubscribe_selected(identity, opts \\ []) do
    projection = dependency(opts, :graph_projection, GraphProjection)
    unsubscribe(opts).(call(projection, :selected_topic, [identity]))
  end

  @spec selected(TrackerIdentity.t(), keyword()) :: term()
  def selected(identity, opts \\ []),
    do: call(dependency(opts, :graph_projection, GraphProjection), :selected, [identity])

  @spec demand(TrackerIdentity.t(), keyword()) :: term()
  def demand(identity, opts \\ []),
    do: call(dependency(opts, :graph_projection, GraphProjection), :demand, [identity])

  @spec refresh(TrackerIdentity.t(), keyword()) :: term()
  def refresh(identity, opts \\ []),
    do: call(dependency(opts, :graph_projection, GraphProjection), :refresh, [identity])

  @spec release(TrackerIdentity.t(), keyword()) :: term()
  def release(identity, opts \\ []),
    do: call(dependency(opts, :graph_projection, GraphProjection), :release, [identity])

  @spec subscribe_sources(keyword()) :: :ok | {:error, term()}
  def subscribe_sources(opts \\ []) do
    with :ok <- call(dependency(opts, :ticket_activity, TicketActivity), :subscribe, []),
         :ok <- call(dependency(opts, :agent_pubsub, AgentPubSub), :subscribe_running, []),
         do: call(dependency(opts, :adhoc_source, AdHocSource), :subscribe, [])
  end

  @spec load_sources(keyword()) :: %{activity: term(), execution: term(), adhoc: term()}
  def load_sources(opts \\ []) do
    Map.put(load_runtime_sources(opts), :adhoc, call(dependency(opts, :adhoc_source, AdHocSource), :snapshot, []))
  end

  @spec load_runtime_sources(keyword()) :: %{activity: term(), execution: term()}
  def load_runtime_sources(opts \\ []) do
    %{
      activity: call(dependency(opts, :ticket_activity, TicketActivity), :snapshots, []),
      execution: call(dependency(opts, :status_report, StatusReport), :snapshot_api, [])
    }
  end

  @spec subscribe_context(TrackerIdentity.t(), keyword()) :: :ok | {:error, term()}
  def subscribe_context(identity, opts \\ []) do
    with :ok <- call(dependency(opts, :ticket_detail_coordinator, TicketDetailCoordinator), :subscribe, [identity]),
         do: call(dependency(opts, :ticket_history_provider, TicketHistoryProvider), :subscribe, [identity])
  end

  @spec unsubscribe_context(TrackerIdentity.t(), keyword()) :: :ok | {:error, term()}
  def unsubscribe_context(identity, opts \\ []) do
    detail = dependency(opts, :ticket_detail_coordinator, TicketDetailCoordinator)
    history = dependency(opts, :ticket_history_provider, TicketHistoryProvider)
    unsubscribe = unsubscribe(opts)

    [
      unsubscribe.(call(detail, :topic, [identity])),
      unsubscribe.(call(history, :topic, [identity]))
    ]
    |> first_error()
  end

  @spec load_context(TrackerIdentity.t(), keyword()) :: %{detail: term(), history: term()}
  def load_context(identity, opts \\ []) do
    %{
      detail: call(dependency(opts, :ticket_detail_coordinator, TicketDetailCoordinator), :request, [identity]),
      history: call(dependency(opts, :ticket_history_provider, TicketHistoryProvider), :request, [identity])
    }
  end

  defp dependency(opts, name, default), do: Keyword.get(opts, name, default)
  defp call(module, function, args), do: apply(module, function, args)

  defp unsubscribe(opts) do
    Keyword.get(opts, :unsubscribe, fn topic -> Phoenix.PubSub.unsubscribe(Aiur.PubSub, topic) end)
  end

  defp first_error(results) do
    Enum.find(results, :ok, &(&1 != :ok))
  end
end
