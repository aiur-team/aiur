defmodule Aiur.Listener do
  @moduledoc "Internal listener-mode control and delivery receipts through the registered delivery target."

  alias Aiur.Listener.{Effective, ModeStore, Receipt}
  alias Aiur.TrackerIdentity

  @type target :: String.t() | TrackerIdentity.t()
  @type result :: {:ok, Effective.view()} | {:error, term()}

  @spec get_mode(target()) :: result()
  def get_mode(target) do
    if valid_target?(target), do: delivery_target().get_mode(target), else: {:error, :invalid_target}
  end

  @doc "Set a mode with required expected_version; actor defaults to human. Reuse the idempotency key on retry."
  @spec set_mode(target(), ModeStore.mode(), keyword()) :: result()
  def set_mode(target, mode, opts) do
    cond do
      not valid_target?(target) -> {:error, :invalid_target}
      mode not in [:sync, :steer, :async] -> {:error, :invalid_mode}
      not (is_integer(opts[:expected_version]) and opts[:expected_version] >= 0) -> {:error, :invalid_expected_version}
      Keyword.get(opts, :actor, :human) not in [:human, :executor, :system] -> {:error, :invalid_actor}
      not (is_nil(opts[:idempotency_key]) or is_binary(opts[:idempotency_key])) -> {:error, :invalid_idempotency_key}
      true -> delivery_target().set_mode(target, mode, opts)
    end
  end

  @doc "Observe a request without treating a claim as provider confirmation."
  @spec receipt(integer(), timeout()) :: {:ok, Receipt.t()} | {:error, term()}
  def receipt(request_id, timeout \\ 5_000) when is_integer(request_id) do
    with {:ok, item} <- delivery_target().read_snapshot(request_id, timeout) do
      {:ok, Receipt.from_snapshot(item)}
    end
  end

  @doc "Classify send acceptance; a timed-out send may still have been enqueued."
  @spec receipt_for_send_result({:ok, term()} | {:error, term()}) :: :accepted | :failed | :outcome_unknown
  def receipt_for_send_result({:error, {:outcome_unknown, _}}), do: :outcome_unknown
  def receipt_for_send_result({:error, _}), do: :failed
  def receipt_for_send_result({:ok, _}), do: :accepted

  defp valid_target?(%TrackerIdentity{identifier: id}), do: is_binary(id) and id != ""
  defp valid_target?(id), do: is_binary(id) and id != ""
  defp delivery_target, do: Application.fetch_env!(:aiur, :listener_delivery_target)
end
