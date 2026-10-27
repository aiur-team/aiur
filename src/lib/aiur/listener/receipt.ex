defmodule Aiur.Listener.Receipt do
  @moduledoc "Pure queue-snapshot projection; provider acknowledgement proves harness queueing only."

  @type t :: %{
          optional(:failure_reason) => term(),
          receipt: :accepted | :held_async | :harness_queued | :failed | :unknown,
          queue_status: atom(),
          listener_mode: atom() | nil,
          observed_at: DateTime.t()
        }

  @spec from_snapshot(map() | nil) :: t()
  def from_snapshot(nil) do
    %{receipt: :unknown, queue_status: :unknown, listener_mode: nil, observed_at: DateTime.utc_now()}
  end

  def from_snapshot(item) do
    base = %{
      receipt: classify(item),
      queue_status: item.status,
      listener_mode: (item.delivery || %{})[:listener_mode_at_claim],
      observed_at: DateTime.utc_now()
    }

    case item.status do
      :failed -> Map.put(base, :failure_reason, item.failure_reason)
      :superseded -> Map.put(base, :failure_reason, :superseded)
      _ -> base
    end
  end

  defp classify(%{status: status}) when status in [:failed, :superseded], do: :failed
  defp classify(%{status: :pending, delivery: %{consume_at: :pull}}), do: :held_async
  defp classify(%{status: :pending}), do: :accepted

  defp classify(%{status: status, provider_delivered_at: %DateTime{}})
       when status in [:delivered, :consumed],
       do: :harness_queued

  defp classify(%{status: status}) when status in [:delivered, :consumed], do: :accepted
  defp classify(_item), do: :unknown
end
