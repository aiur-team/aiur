defmodule Aiur.AppServer.InterruptHandshake do
  @moduledoc """
  Reconciles successful interrupt responses with provider idle notifications.
  """

  @type result :: {:ready, map(), map()} | {:waiting, map()}

  @spec initial_state() :: map()
  def initial_state, do: %{interrupt_acknowledged?: false, interrupt_idle_seen?: false}

  @spec acknowledge(map(), map()) :: result()
  def acknowledge(state, payload) do
    state
    |> Map.put(:pending_interrupt_request_id, nil)
    |> Map.put(:interrupt_acknowledged?, true)
    |> Map.put(:interrupt_acknowledgement, payload)
    |> reconcile()
  end

  @spec observe_idle(map(), map()) :: result()
  def observe_idle(state, payload) do
    state
    |> Map.put(:interrupt_idle_seen?, true)
    |> Map.put(:interrupt_idle_payload, payload)
    |> reconcile()
  end

  defp reconcile(state) do
    if state.interrupt_action in [:pause, :operator_message] and
         Map.get(state, :interrupt_acknowledged?, false) and
         Map.get(state, :interrupt_idle_seen?, false) do
      {:ready, state,
       %{
         "status" => "interrupted",
         "acknowledgement" => Map.get(state, :interrupt_acknowledgement),
         "idle" => Map.get(state, :interrupt_idle_payload)
       }}
    else
      {:waiting, state}
    end
  end
end
