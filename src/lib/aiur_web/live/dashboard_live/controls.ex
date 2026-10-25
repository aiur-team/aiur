defmodule AiurWeb.DashboardLive.Controls do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias Aiur.AgentPubSub
  alias Aiur.Orchestrator.Slots
  alias AiurWeb.{DashboardLive, EndpointConfig}
  alias AiurWeb.OperatorControlCenter.{PauseState, UnitControls, UnitsControlPolicy, UnitsPresenter}

  @doc false
  @spec toggle_global_pause(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def toggle_global_pause(socket) do
    socket
    |> assign(:globally_paused, global_pause_state(socket.assigns.payload))
    |> PauseState.toggle()
    |> DashboardLive.reload_after_action()
  end

  @doc false
  @spec global_pause_state(map()) :: boolean() | :loading | nil
  def global_pause_state(%{fleet: %{error: _error}}) do
    PauseState.pause_state(capacity_orchestrator())
  rescue
    _endpoint_unavailable -> nil
  catch
    :exit, _reason -> nil
  end

  def global_pause_state(%{fleet: %{globally_paused: paused}}) when is_boolean(paused), do: paused
  def global_pause_state(_payload), do: nil

  @doc false
  @spec adjust_capacity(Phoenix.LiveView.Socket.t(), integer()) :: Phoenix.LiveView.Socket.t()
  def adjust_capacity(socket, delta) do
    prior = capacity_max(socket.assigns.payload)
    reconcile_capacity(socket, capacity_adjust(delta), prior)
  end

  @doc false
  @spec set_capacity(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def set_capacity(socket, value) do
    case parse_capacity(value) do
      {:ok, next} ->
        prior = capacity_max(socket.assigns.payload)
        reconcile_capacity(socket, capacity_set(next), prior)

      :error ->
        assign(socket, :capacity_feedback, %{kind: :invalid})
    end
  end

  defp reconcile_capacity(socket, {:ok, %{} = status}, prior) do
    new_max = Map.get(status, :max)

    kind =
      cond do
        is_integer(prior) and new_max == prior -> :noop
        Map.get(status, :draining?) == true -> :draining
        true -> :applied
      end

    socket
    |> DashboardLive.reload_after_action()
    |> assign(:capacity_feedback, %{kind: kind, max: new_max})
  end

  defp reconcile_capacity(socket, {:error, reason}, _prior) do
    assign(socket, :capacity_feedback, %{kind: capacity_error_kind(reason)})
  end

  defp capacity_error_kind(:timeout), do: :timeout
  defp capacity_error_kind(_reason), do: :unavailable

  defp parse_capacity(value) do
    case value |> to_string() |> String.trim() |> Integer.parse() do
      {next, ""} when next >= 1 -> {:ok, next}
      _other -> :error
    end
  end

  @doc false
  @spec capacity_facts(map()) :: map() | nil
  def capacity_facts(payload), do: get_in(payload, [:fleet, :capacity])

  defp capacity_max(payload) do
    case capacity_facts(payload) do
      %{max: max} when is_integer(max) -> max
      _other -> nil
    end
  end

  defp capacity_adjust(delta) do
    case EndpointConfig.get(:capacity_adjust_fun) do
      fun when is_function(fun, 1) -> fun.(delta)
      _other -> Slots.adjust_max_concurrent_agents(capacity_orchestrator(), delta)
    end
  end

  defp capacity_set(next) do
    case EndpointConfig.get(:capacity_set_fun) do
      fun when is_function(fun, 1) -> fun.(next)
      _other -> Slots.set_max_concurrent_agents(capacity_orchestrator(), next)
    end
  end

  @doc false
  @spec capacity_orchestrator() :: GenServer.server()
  def capacity_orchestrator, do: EndpointConfig.get(:orchestrator) || Aiur.Orchestrator

  @doc false
  @spec pause_agent(Aiur.TrackerIdentity.t() | String.t()) :: term()
  def pause_agent(target), do: UnitControls.pause(target)

  @doc false
  @spec request_unit_control(Phoenix.LiveView.Socket.t(), String.t(), :pause | :resume) :: Phoenix.LiveView.Socket.t()
  def request_unit_control(socket, token, action) do
    catalog = Map.get(socket.assigns.payload, :units, %{})

    row =
      case UnitsPresenter.lookup(catalog, token) do
        {:ok, row} -> row
        {:error, :not_found} -> nil
      end

    {controls, identifier} = UnitControls.request(socket.assigns.unit_controls, token, row, action)
    socket = assign(socket, :unit_controls, controls)
    if identifier, do: sync_unit_control_subscriptions(socket, connected?(socket)), else: socket
  end

  @doc false
  @spec apply_control_lifecycle(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def apply_control_lifecycle(socket, payload) do
    {controls, _key} = UnitControls.apply_lifecycle(socket.assigns.unit_controls, payload)
    assign(socket, :unit_controls, controls)
  end

  @doc false
  @spec sync_unit_control_subscriptions(Phoenix.LiveView.Socket.t(), boolean()) :: Phoenix.LiveView.Socket.t()
  def sync_unit_control_subscriptions(socket, false), do: socket

  def sync_unit_control_subscriptions(socket, true) do
    desired = controllable_identifiers(socket)
    current = socket.assigns.unit_control_subscriptions

    Enum.each(MapSet.difference(desired, current), &AgentPubSub.subscribe_agent/1)
    Enum.each(MapSet.difference(current, desired), &AgentPubSub.unsubscribe_agent/1)

    assign(socket, :unit_control_subscriptions, desired)
  end

  # Subscribe to units that are controllable now, unioned with any unit that
  # still has an in-flight control, so a request whose row leaves the running
  # bucket mid-flight keeps its subscription until the lifecycle settles it.
  defp controllable_identifiers(socket) do
    running =
      socket.assigns.payload
      |> Map.get(:units, %{})
      |> unit_rows()
      |> Enum.filter(&(get_in(&1, [:runtime, :bucket]) == :running))
      |> Enum.map(&UnitsControlPolicy.identifier/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    MapSet.union(running, in_flight_control_identifiers(socket))
  end

  defp in_flight_control_identifiers(socket), do: UnitControls.in_flight_identifiers(socket.assigns.unit_controls)

  @doc false
  @spec reconcile_unit_controls(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reconcile_unit_controls(socket) do
    catalog = Map.get(socket.assigns.payload, :units, %{})
    rows = Map.new(unit_rows(catalog), &{UnitsPresenter.row_token(&1), &1})
    assign(socket, :unit_controls, UnitControls.reconcile(socket.assigns.unit_controls, &Map.get(rows, &1)))
  end

  defp unit_rows(%{snapshot: %{rows: rows}}) when is_list(rows), do: rows
  defp unit_rows(_catalog), do: []
end
