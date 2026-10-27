defmodule Aiur.Orchestrator.ListenerDeliveryTarget do
  @moduledoc "Routes internal listener control to the Orchestrator mailbox."
  @behaviour Aiur.Listener.DeliveryTarget

  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.OperatorMessages

  @impl true
  def get_mode(target), do: call({:listener_get_mode, target}, 5_000, {:error, :timeout})

  @impl true
  def set_mode(target, mode, opts) do
    unknown = {:error, {:outcome_unknown, %{idempotency_key: opts[:idempotency_key]}}}
    call({:listener_set_mode, target, mode, opts}, OperatorMessages.operator_message_call_timeout_ms(), unknown)
  end

  defp call(request, timeout, timeout_result) do
    GenServer.call(Orchestrator, request, timeout)
  catch
    :exit, {:timeout, _} -> timeout_result
    :exit, _ -> {:error, :unavailable}
  end
end
