defmodule AiurWeb.DashboardLive.Controls do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias Aiur.{AgentChat, AgentPubSub}
  alias Aiur.Orchestrator.{GlobalPause, Slots}
  alias AiurWeb.{DashboardLive, EndpointConfig}
  alias AiurWeb.OperatorControlCenter.{PauseState, UnitsControlPolicy, UnitsPresenter}

  @doc false
  @spec toggle_global_pause(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def toggle_global_pause(socket) do
    target = not global_paused?(socket.assigns.payload)

    case GlobalPause.set_global_pause(capacity_orchestrator(), target, "dashboard") do
      {:ok, _status} ->
        socket
        |> assign(:global_pause_error, nil)
        |> DashboardLive.reload_after_action()

      {:error, {:global_pause_persistence_failed, _reason}} ->
        assign(
          socket,
          :global_pause_error,
          "Global pause was not changed because its state could not be persisted. The daemon remains in its previous state; check the daemon log and retry."
        )

      {:error, reason} ->
        assign(socket, :global_pause_error, "Global pause could not be changed: #{inspect(reason)}")
    end
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

  defp global_paused?(payload) when is_map(payload) do
    payload |> Map.get(:fleet, %{}) |> Map.get(:globally_paused, false) == true
  end

  defp global_paused?(_payload), do: false

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
  def pause_agent(target) do
    case EndpointConfig.get(:agent_chat_pause_fun) do
      fun when is_function(fun, 1) -> fun.(target)
      _fun -> AgentChat.pause(target)
    end
  end

  # --- Unit controls (DASH-005) --------------------------------------------

  # Resolve the row server-side by opaque token, recheck live capability, then
  # invoke DASH-004. Applied state is mirrored only from lifecycle evidence, so
  # this only records the request; it never mutates the row's lifecycle.
  @doc false
  @spec request_unit_control(Phoenix.LiveView.Socket.t(), String.t(), :pause | :resume) :: Phoenix.LiveView.Socket.t()
  def request_unit_control(socket, token, action) do
    control = Map.get(socket.assigns.unit_controls, token)

    if UnitsControlPolicy.settled?(control) do
      resolve_unit_control_row(socket, token, action)
    else
      # A request for this unit is already pending; activation is idempotent.
      socket
    end
  end

  defp resolve_unit_control_row(socket, token, action) do
    catalog = Map.get(socket.assigns.payload, :units, %{})

    case UnitsPresenter.lookup(catalog, token) do
      {:ok, row} -> invoke_unit_control(socket, token, row, action)
      {:error, :not_found} -> socket
    end
  end

  defp invoke_unit_control(socket, token, row, action) do
    case UnitsControlPolicy.identifier(row) do
      nil ->
        put_unit_control(socket, token, %{action: action, status: :no_identity, identifier: nil})

      identifier ->
        recheck_and_invoke(socket, token, identifier, action)
    end
  end

  defp recheck_and_invoke(socket, token, identifier, action) do
    case unit_capabilities(identifier) do
      {:ok, capabilities} ->
        recheck_result(socket, token, identifier, action, UnitsControlPolicy.recheck(capabilities, action))

      {:error, reason} ->
        put_unit_control(socket, token, UnitsControlPolicy.settle_error(action, reason, identifier))
    end
  end

  defp recheck_result(socket, token, identifier, action, :ok),
    do: dispatch_unit_control(socket, token, identifier, action)

  defp recheck_result(socket, token, identifier, action, {:error, reason}),
    do: put_unit_control(socket, token, %{action: action, status: reason, identifier: identifier})

  defp dispatch_unit_control(socket, token, identifier, action) do
    case invoke_control_owner(action, identifier) do
      {:ok, result} ->
        # Subscribe to this unit's agent topic now, before its lifecycle
        # evidence can arrive, even if the row is not in the :running bucket the
        # periodic subscription sync tracks. The pending control is also unioned
        # into the sync set so the subscription survives reloads until it settles.
        socket
        |> put_unit_control(token, %{
          action: action,
          status: :requested,
          request_id: control_request_id(result),
          identifier: identifier
        })
        |> ensure_control_subscription(identifier)

      {:error, reason} ->
        put_unit_control(socket, token, UnitsControlPolicy.settle_error(action, reason, identifier))
    end
  end

  defp ensure_control_subscription(socket, identifier) do
    subscriptions = socket.assigns.unit_control_subscriptions

    if connected?(socket) and not MapSet.member?(subscriptions, identifier) do
      AgentPubSub.subscribe_agent(identifier)
      assign(socket, :unit_control_subscriptions, MapSet.put(subscriptions, identifier))
    else
      socket
    end
  end

  defp invoke_control_owner(:pause, identifier), do: pause_agent(identifier)
  defp invoke_control_owner(:resume, identifier), do: resume_agent(identifier)

  defp control_request_id(result) when is_integer(result), do: result
  defp control_request_id(_result), do: nil

  defp put_unit_control(socket, token, control_state) do
    assign(socket, :unit_controls, Map.put(socket.assigns.unit_controls, token, control_state))
  end

  defp resume_agent(identifier) do
    case EndpointConfig.get(:agent_chat_resume_fun) do
      fun when is_function(fun, 1) -> fun.(identifier)
      _fun -> AgentChat.resume(identifier)
    end
  end

  defp unit_capabilities(identifier) do
    case EndpointConfig.get(:agent_chat_capabilities_fun) do
      fun when is_function(fun, 1) -> fun.(identifier)
      _fun -> AgentChat.capabilities(identifier)
    end
  end

  @doc false
  @spec apply_control_lifecycle(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def apply_control_lifecycle(socket, payload) do
    identifier = get_in(payload, [:tracker_identity, :identifier])

    case find_control_token(socket.assigns.unit_controls, identifier) do
      {token, control} ->
        put_unit_control(socket, token, UnitsControlPolicy.apply_lifecycle(control, payload))

      nil ->
        socket
    end
  end

  defp find_control_token(controls, identifier) when is_binary(identifier) do
    Enum.find(controls, fn {_token, control} -> Map.get(control, :identifier) == identifier end)
  end

  defp find_control_token(_controls, _identifier), do: nil

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

  defp in_flight_control_identifiers(socket) do
    socket.assigns.unit_controls
    |> Enum.reject(fn {_token, control} -> UnitsControlPolicy.settled?(control) end)
    |> Enum.map(fn {_token, control} -> Map.get(control, :identifier) end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # A changed or terminal row cancels stale in-flight UI intent rather than
  # targeting a replacement unit; settled states are left untouched.
  @doc false
  @spec reconcile_unit_controls(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reconcile_unit_controls(%{assigns: %{unit_controls: controls}} = socket) when controls == %{},
    do: socket

  def reconcile_unit_controls(socket) do
    catalog = Map.get(socket.assigns.payload, :units, %{})
    rows_by_token = Map.new(unit_rows(catalog), fn row -> {UnitsPresenter.row_token(row), row} end)

    reconciled =
      Map.new(socket.assigns.unit_controls, fn {token, control} ->
        {token, reconcile_control(control, Map.get(rows_by_token, token))}
      end)

    assign(socket, :unit_controls, reconciled)
  end

  defp reconcile_control(control, row) do
    if UnitsControlPolicy.settled?(control) or not stale_control_row?(row) do
      control
    else
      Map.put(control, :status, :state_changed)
    end
  end

  defp stale_control_row?(nil), do: true

  defp stale_control_row?(row),
    do: Map.get(row, :terminal?) == true or Map.get(row, :replacement_boundary?) == true

  defp unit_rows(%{snapshot: %{rows: rows}}) when is_list(rows), do: rows
  defp unit_rows(_catalog), do: []
end
