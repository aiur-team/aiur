defmodule Aiur.Orchestrator.ListenerDeliveryTarget do
  @moduledoc "Routes internal listener control to the Orchestrator mailbox."
  @behaviour Aiur.Listener.DeliveryTarget

  alias Aiur.Conversation.Ref
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.OperatorMessages

  @impl true
  def executor_delivery_installed?, do: Code.ensure_loaded?(OperatorMessages.ExecutorHookClaims)

  @impl true
  def enqueue(target, text, opts) do
    payload = %{
      kind: :text,
      body: text,
      delivery_policy: Keyword.fetch!(opts, :delivery_policy),
      origin: Keyword.fetch!(opts, :origin),
      fallback: Keyword.get(opts, :fallback, :queue_next),
      turn_id: Keyword.get(opts, :turn_id),
      message_id: Keyword.get(opts, :client_request_id, opts[:message_id])
    }

    payload = Map.merge(payload, Map.new(Keyword.take(opts, [:actor, :correlation])))
    Orchestrator.send_operator_message(queue_target(target), payload)
  end

  @impl true
  def get_mode(target), do: call({:listener_get_mode, target}, 5_000, {:error, :timeout})

  @impl true
  def set_mode(target, mode, opts) do
    unknown = {:error, {:outcome_unknown, %{idempotency_key: opts[:idempotency_key]}}}
    call({:listener_set_mode, target, mode, opts}, OperatorMessages.operator_message_call_timeout_ms(), unknown)
  end

  @impl true
  def read_snapshot(id, timeout), do: OperatorMessages.Snapshot.read(Orchestrator, id, timeout)

  # The hook consumer owns this queue key; external sessions never become worker runners.
  defp queue_target(%Ref{v: 1, subject: :executor}), do: "executor"
  defp queue_target(target), do: target

  defp call(request, timeout, timeout_result) do
    GenServer.call(Orchestrator, request, timeout)
  catch
    :exit, {:timeout, _} -> timeout_result
    :exit, _ -> {:error, :unavailable}
  end
end
