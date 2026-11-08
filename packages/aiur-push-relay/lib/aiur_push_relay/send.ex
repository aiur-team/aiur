defmodule AiurPushRelay.Send do
  @moduledoc "Serializes queue admission and idempotency; provider work runs outside the request."
  use GenServer
  alias AiurPushRelay.Store

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def enqueue(server, row, envelope), do: GenServer.call(server, {:enqueue, row, envelope})

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_call({:enqueue, row, envelope}, _, state) do
    result =
      case Store.call(state.store, :reserve, [row, envelope, System.system_time(:second)]) do
        :new -> admit(state, row, envelope)
        {:duplicate, status} -> {:ok, status}
        error -> error
      end

    {:reply, result, state}
  end

  defp admit(state, row, envelope) do
    case start_delivery(state, row, envelope) do
      {:ok, _pid} ->
        {:ok, 202}

      _ ->
        Store.call(state.store, :release, [row.handle, envelope["idempotency_key"]])
        {:error, :queue_unavailable}
    end
  end

  defp start_delivery(state, row, envelope) do
    Task.Supervisor.start_child(state.tasks, fn ->
      status = AiurPushRelay.Delivery.run(state.provider, row, envelope)
      Store.call(state.store, :finish, [row.handle, envelope["idempotency_key"], status])
      AiurPushRelay.Delivery.log(row.handle, envelope, status)
    end)
  catch
    :exit, _ -> {:error, :queue_unavailable}
  end
end
