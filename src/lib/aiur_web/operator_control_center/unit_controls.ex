defmodule AiurWeb.OperatorControlCenter.UnitControls do
  @moduledoc "Shared DASH-005 dispatch, correlation and reconciliation for dashboard surfaces."
  alias Aiur.AgentChat
  alias AiurWeb.EndpointConfig
  alias AiurWeb.OperatorControlCenter.UnitsControlPolicy, as: Policy

  @type controls :: %{optional(String.t()) => Policy.control_state()}

  @spec request(controls(), String.t(), map() | nil, :pause | :resume) :: {controls(), String.t() | nil}
  def request(controls, _key, nil, _action), do: {controls, nil}

  def request(controls, key, row, action) do
    if Policy.settled?(Map.get(controls, key)) do
      {control, subscription} = invoke(row, action)
      {Map.put(controls, key, control), subscription}
    else
      {controls, nil}
    end
  end

  defp invoke(row, action) do
    case Policy.identifier(row) do
      nil -> {%{action: action, status: :no_identity, identifier: nil}, nil}
      identifier -> recheck(identifier, action)
    end
  end

  defp recheck(identifier, action) do
    case capabilities(identifier) do
      {:ok, capabilities} ->
        case Policy.recheck(capabilities, action) do
          :ok -> dispatch(identifier, action)
          {:error, reason} -> {%{action: action, status: reason, identifier: identifier}, nil}
        end

      {:error, reason} ->
        {Policy.settle_error(action, reason, identifier), nil}
    end
  end

  defp dispatch(identifier, action) do
    result = if action == :pause, do: pause(identifier), else: resume(identifier)

    case result do
      {:ok, result} ->
        request_id = if is_integer(result), do: result
        {%{action: action, status: :requested, request_id: request_id, identifier: identifier}, identifier}

      {:error, reason} ->
        {Policy.settle_error(action, reason, identifier), nil}
    end
  end

  @spec apply_lifecycle(controls(), map()) :: {controls(), String.t() | nil}
  def apply_lifecycle(controls, payload) do
    identifier = get_in(payload, [:tracker_identity, :identifier])
    entry = if is_binary(identifier), do: Enum.find(controls, fn {_key, control} -> control[:identifier] == identifier end)

    case entry do
      {key, control} -> {Map.put(controls, key, Policy.apply_lifecycle(control, payload)), key}
      nil -> {controls, nil}
    end
  end

  @spec reconcile(controls(), (String.t() -> map() | nil)) :: controls()
  def reconcile(controls, lookup) do
    Map.new(controls, fn {key, control} ->
      row = lookup.(key)
      stale = is_nil(row) or row[:terminal?] == true or row[:replacement_boundary?] == true
      {key, if(not Policy.settled?(control) and stale, do: Map.put(control, :status, :state_changed), else: control)}
    end)
  end

  @spec in_flight_identifiers(controls()) :: MapSet.t(String.t())
  def in_flight_identifiers(controls) do
    controls |> Map.values() |> Enum.reject(&Policy.settled?/1) |> Enum.map(& &1[:identifier]) |> Enum.reject(&is_nil/1) |> MapSet.new()
  end

  @spec pause(Aiur.TrackerIdentity.t() | String.t()) :: term()
  def pause(target), do: call(:agent_chat_pause_fun, &AgentChat.pause/1, target)
  @spec resume(String.t()) :: term()
  def resume(identifier), do: call(:agent_chat_resume_fun, &AgentChat.resume/1, identifier)
  @spec capabilities(String.t()) :: term()
  def capabilities(identifier), do: call(:agent_chat_capabilities_fun, &AgentChat.capabilities/1, identifier)

  defp call(key, default, target) do
    case EndpointConfig.get(key) do
      fun when is_function(fun, 1) -> fun.(target)
      _ -> default.(target)
    end
  end
end
