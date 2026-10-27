defmodule AiurWeb.Build.Controls do
  @moduledoc false
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, push_event: 3]
  alias Aiur.AgentPubSub
  alias AiurWeb.Build.{DataSource, Payload, Read, TicketControl, URLState}
  alias AiurWeb.EndpointConfig
  alias AiurWeb.OperatorControlCenter.{UnitControls, UnitsControlPolicy}

  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket), do: assign(socket, unit_controls: %{}, control_subscriptions: MapSet.new(), control_by_you: %{})

  @spec request(Phoenix.LiveView.Socket.t(), map()) :: tuple()
  def request(socket, %{"id" => id, "action" => action}) when is_binary(id) and action in ["pause", "resume"] do
    cond do
      not writable?(socket) -> {:reply, Payload.error(:read_only), assign(socket, :writable, false)}
      not valid?(id) -> {:reply, Payload.error(:invalid_params), socket}
      true -> dispatch(socket, id, String.to_existing_atom(action))
    end
  end

  def request(socket, _params), do: {:reply, Payload.error(:invalid_params), socket}

  defp dispatch(socket, id, action) do
    case row(socket, id) do
      nil ->
        {:reply, Payload.error(:unavailable), push_event(socket, "build-ticket-control", body(socket, id, nil))}

      row ->
        socket = subscribe_before_dispatch(socket, row)
        {controls, _subscription} = UnitControls.request(socket.assigns.unit_controls, id, row, action)
        socket = socket |> assign(:unit_controls, controls) |> subscriptions()
        message = body(socket, id, row)
        {:reply, message, push_event(socket, "build-ticket-control", message)}
    end
  end

  @spec open_conversation(Phoenix.LiveView.Socket.t(), map()) :: tuple()
  def open_conversation(socket, %{"id" => id}) when is_binary(id) do
    # /chat/... now redirects back to this modal; C14-T03 adds the conversation page.
    {:reply, Payload.error(if(valid?(id), do: :unavailable, else: :invalid_params)), socket}
  end

  def open_conversation(socket, _params), do: {:reply, Payload.error(:invalid_params), socket}

  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(socket) do
    ids = Enum.uniq([open_id(socket) | in_flight_keys(socket) ++ Map.keys(socket.assigns.control_by_you)]) |> Enum.reject(&is_nil/1)
    rows = Map.new(ids, &{&1, row(socket, &1)})
    controls = UnitControls.reconcile(socket.assigns.unit_controls, &Map.get(rows, &1))
    by_you = Map.filter(socket.assigns.control_by_you, fn {id, _at} -> paused?(rows[id]) end)
    socket = socket |> assign(unit_controls: controls, control_by_you: by_you) |> subscriptions()
    if id = open_id(socket), do: push_event(socket, "build-ticket-control", body(socket, id, rows[id])), else: socket
  end

  @spec lifecycle(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def lifecycle(socket, payload) do
    previous = socket.assigns.unit_controls[get_in(payload, [:tracker_identity, :identifier])]

    if UnitsControlPolicy.settled?(previous) do
      socket
    else
      apply_lifecycle(socket, previous, payload)
    end
  end

  defp apply_lifecycle(socket, previous, payload) do
    {controls, key} = UnitControls.apply_lifecycle(socket.assigns.unit_controls, payload)
    socket = socket |> assign(:unit_controls, controls) |> subscriptions()
    socket = record_pause(socket, key, previous, controls[key], payload)
    if key != nil and key == open_id(socket), do: push_event(socket, "build-ticket-control", body(socket, key, row(socket, key))), else: socket
  end

  defp record_pause(socket, key, previous, %{action: :pause, status: :applied}, payload) do
    if UnitsControlPolicy.settled?(previous) do
      socket
    else
      case payload[:applied_at] do
        %DateTime{} = at -> assign(socket, :control_by_you, Map.put(socket.assigns.control_by_you, key, DateTime.to_unix(at, :millisecond)))
        at when is_integer(at) -> assign(socket, :control_by_you, Map.put(socket.assigns.control_by_you, key, at))
        _ -> socket
      end
    end
  end

  defp record_pause(socket, _key, _previous, _control, _payload), do: socket

  @spec body(Phoenix.LiveView.Socket.t(), String.t(), map() | nil) :: map()
  def body(socket, id, row) do
    control = socket.assigns.unit_controls[id]
    at = if paused?(row) and match?(%{action: :pause, status: :applied}, control), do: socket.assigns.control_by_you[id]
    TicketControl.encode(row, control, writable?(socket)) |> Map.merge(%{v: 1, kind: "control", id: id, by_you_at: at}) |> Payload.scrub()
  end

  @spec read_body(Phoenix.LiveView.Socket.t(), String.t()) :: map()
  def read_body(socket, id), do: body(socket, id, row(socket, id))

  defp row(socket, id) do
    source = socket.assigns.build_source
    opts = Read.source_opts(socket)

    case Read.safe_read(fn -> DataSource.call(source, :unit_row, [id, opts]) end) do
      {:ok, row} -> row
      {:error, _} -> nil
    end
  end

  # A worker may publish its lifecycle before the synchronous owner call returns.
  defp subscribe_before_dispatch(socket, row) do
    identifier = UnitsControlPolicy.identifier(row)
    current = socket.assigns.control_subscriptions

    if is_binary(identifier) and connected?(socket) and not MapSet.member?(current, identifier) do
      AgentPubSub.subscribe_agent(identifier)
      assign(socket, :control_subscriptions, MapSet.put(current, identifier))
    else
      socket
    end
  end

  defp subscriptions(socket) do
    desired = UnitControls.in_flight_identifiers(socket.assigns.unit_controls)
    current = socket.assigns.control_subscriptions

    if connected?(socket) do
      Enum.each(MapSet.difference(desired, current), &AgentPubSub.subscribe_agent/1)
      Enum.each(MapSet.difference(current, desired), &AgentPubSub.unsubscribe_agent/1)
    end

    assign(socket, :control_subscriptions, desired)
  end

  defp in_flight_keys(socket) do
    socket.assigns.unit_controls |> Enum.reject(fn {_id, control} -> UnitsControlPolicy.settled?(control) end) |> Enum.map(&elem(&1, 0))
  end

  defp open_id(socket), do: socket.assigns[:url_state] && socket.assigns.url_state.ticket
  defp valid?(id), do: URLState.parse(%{"ticket" => id}).ticket == id
  defp writable?(socket), do: socket.assigns.writable and EndpointConfig.get(:dashboard_writable) == true
  defp paused?(row), do: is_map(row) and (get_in(row, [:runtime, :work_state]) in [:paused, :sleeping] or get_in(row, [:runtime, :tracker_paused?]) == true)
end
