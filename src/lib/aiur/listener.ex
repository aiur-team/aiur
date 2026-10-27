defmodule Aiur.Listener do
  @moduledoc "Listener delivery receipts for queued agent messages."

  alias Aiur.Listener.Receipt
  alias Aiur.Orchestrator.OperatorMessages.Snapshot

  @doc "Observe a request without treating a claim as provider confirmation."
  @spec receipt(integer(), timeout()) :: {:ok, Receipt.t()} | {:error, term()}
  def receipt(request_id, timeout \\ 5_000) when is_integer(request_id) do
    with {:ok, item} <- Snapshot.read(Aiur.Orchestrator, request_id, timeout) do
      {:ok, Receipt.from_snapshot(item)}
    end
  end

  @doc "Classify send acceptance; a timed-out send may still have been enqueued."
  @spec receipt_for_send_result({:ok, term()} | {:error, term()}) :: :accepted | :failed | :outcome_unknown
  def receipt_for_send_result({:error, {:outcome_unknown, _}}), do: :outcome_unknown
  def receipt_for_send_result({:error, _}), do: :failed
  def receipt_for_send_result({:ok, _}), do: :accepted
end
