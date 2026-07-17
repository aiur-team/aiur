defmodule AiurWeb.BuildOrder.SourceRuntime do
  @moduledoc "Projection and cached execution/activity orchestration for Build Order routes."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, start_async: 3]

  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.{ContextRuntime, RouteState, Runtime}
  alias AiurWeb.BuildOrderPresenter
  alias Phoenix.LiveView.Socket

  @spec initialize(Socket.t(), module() | {module(), term()}) :: Socket.t()
  def initialize(socket, source) do
    socket
    |> assign(:source, source)
    |> assign(:sources, Runtime.unavailable_sources())
    |> assign(:source_reload_loading?, false)
    |> assign(:source_reload_queued?, false)
    |> assign(:model, nil)
  end

  @spec connect(Socket.t()) :: Socket.t()
  def connect(socket) do
    _ = Runtime.safe_source_call(socket.assigns.source, :subscribe_catalog, [], :ok)
    _ = Runtime.safe_source_call(socket.assigns.source, :subscribe_sources, [], :ok)

    socket
    |> reload_catalog()
    |> ensure_reload()
  end

  @spec reset(Socket.t(), integer()) :: Socket.t()
  def reset(socket, _generation) do
    previous_repository = catalog_repository(socket.assigns.route_state)

    if previous_repository do
      _ = Runtime.safe_source_call(socket.assigns.source, :unsubscribe_catalog, [previous_repository], :ok)
    end

    _ = Runtime.safe_source_call(socket.assigns.source, :subscribe_catalog, [], :ok)
    {route_state, effects} = RouteState.reset(socket.assigns.route_state)

    socket
    |> assign(:route_state, route_state)
    |> apply_effects(effects)
    |> reload_catalog()
    |> assign_model()
  end

  @spec accept_projection(Socket.t(), Snapshot.t()) :: Socket.t()
  def accept_projection(socket, %Snapshot{scope: :catalog} = snapshot) do
    {route_state, effects} = RouteState.put_catalog(socket.assigns.route_state, snapshot)

    socket
    |> assign(:route_state, route_state)
    |> apply_effects(effects)
    |> assign_model()
  end

  def accept_projection(socket, %Snapshot{} = snapshot) do
    case RouteState.put_selected(socket.assigns.route_state, snapshot) do
      {route_state, :generation} ->
        socket
        |> assign(:route_state, route_state)
        |> assign_model()
        |> schedule_reload()

      {route_state, :health} ->
        socket |> assign(:route_state, route_state) |> assign_model()

      {_route_state, :ignored} ->
        socket
    end
  end

  @spec apply_effects(Socket.t(), [RouteState.effect()]) :: Socket.t()
  def apply_effects(socket, effects) do
    Enum.reduce(effects, socket, fn
      {:deactivate, identity}, socket ->
        deactivate(socket.assigns.source, identity)
        socket

      {:activate, identity}, socket ->
        activate(socket, identity)
    end)
  end

  @spec schedule_reload(Socket.t()) :: Socket.t()
  def schedule_reload(%{assigns: %{source_reload_loading?: true}} = socket),
    do: assign(socket, :source_reload_queued?, true)

  def schedule_reload(socket) do
    if connected?(socket) do
      source = socket.assigns.source
      token = RouteState.async_token(socket.assigns.route_state, :sources)

      socket
      |> assign(:source_reload_loading?, true)
      |> start_async(:build_order_sources, fn ->
        {token, Runtime.safe_source_call(source, :load_sources, [], Runtime.unavailable_sources())}
      end)
    else
      socket
    end
  end

  @spec complete_reload(Socket.t(), term(), term()) :: Socket.t()
  def complete_reload(socket, token, sources) do
    socket = assign(socket, :source_reload_loading?, false)

    socket =
      if RouteState.current_async?(socket.assigns.route_state, token, :sources) and valid_sources?(sources) do
        socket |> assign(:sources, sources) |> assign_model()
      else
        socket
      end

    finish_reload(socket)
  end

  @spec failed_reload(Socket.t()) :: Socket.t()
  def failed_reload(socket),
    do: socket |> assign(:source_reload_loading?, false) |> finish_reload()

  @spec assign_model(Socket.t()) :: Socket.t()
  def assign_model(socket) do
    model =
      case RouteState.selected_snapshot(socket.assigns.route_state) do
        %Snapshot{} = snapshot ->
          BuildOrderPresenter.present(snapshot, socket.assigns.sources.execution, socket.assigns.sources.activity)

        _snapshot ->
          nil
      end

    socket
    |> assign(:model, model)
    |> ContextRuntime.reconcile()
  end

  @spec terminate(Socket.t()) :: :ok
  def terminate(socket) do
    case RouteState.selected_identity(socket.assigns.route_state) do
      %TrackerIdentity{} = identity -> deactivate(socket.assigns.source, identity)
      _identity -> :ok
    end
  end

  defp reload_catalog(socket) do
    snapshot = Runtime.safe_source_call(socket.assigns.source, :catalog, [], nil)
    {route_state, effects} = RouteState.put_catalog(socket.assigns.route_state, snapshot)

    socket
    |> assign(:route_state, route_state)
    |> apply_effects(effects)
  end

  defp activate(socket, identity) do
    if connected?(socket) do
      source = socket.assigns.source
      _ = Runtime.safe_source_call(source, :subscribe_selected, [identity], :ok)

      socket =
        case Runtime.safe_source_call(source, :demand, [identity], {:error, :unavailable}) do
          {:ok, %Snapshot{} = snapshot} ->
            {route_state, _accepted} = RouteState.put_selected(socket.assigns.route_state, snapshot)
            assign(socket, :route_state, route_state)

          _failure ->
            assign(socket, :route_state, RouteState.demand_failed(socket.assigns.route_state, identity))
        end

      schedule_reload(socket)
    else
      socket
    end
  end

  defp deactivate(source, identity) do
    _ = Runtime.safe_source_call(source, :release, [identity], :ok)
    _ = Runtime.safe_source_call(source, :unsubscribe_selected, [identity], :ok)
    :ok
  end

  defp finish_reload(%{assigns: %{source_reload_queued?: true}} = socket) do
    socket |> assign(:source_reload_queued?, false) |> schedule_reload()
  end

  defp finish_reload(socket), do: socket

  defp ensure_reload(%{assigns: %{source_reload_loading?: true}} = socket), do: socket
  defp ensure_reload(socket), do: schedule_reload(socket)

  defp valid_sources?(%{execution: _execution, activity: _activity}), do: true
  defp valid_sources?(_sources), do: false

  defp catalog_repository(route_state) do
    case RouteState.catalog_snapshot(route_state) do
      %Snapshot{repository: {_owner, _repository} = repository} -> repository
      _snapshot -> nil
    end
  end
end
