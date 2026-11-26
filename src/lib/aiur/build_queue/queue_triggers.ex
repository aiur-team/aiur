defmodule Aiur.BuildQueue.QueueTriggers do
  @moduledoc false
  alias Aiur.BuildQueue.Model

  @spec add(Model.Queue.t(), Model.t(), keyword()) :: {:ok, Model.Queue.t()} | {:error, atom()}
  def add(queue, document, opts) do
    trigger = Keyword.get(opts, :start_trigger, queue.start_trigger)
    existing? = Enum.any?(document.queues, &(&1.id == queue.id))

    cond do
      not valid?(trigger) -> {:error, :invalid_start_trigger}
      existing? and trigger != queue.start_trigger -> {:error, :trigger_mismatch}
      true -> {:ok, %{queue | start_trigger: trigger}}
    end
  end

  @spec set(Model.t(), String.t(), Aiur.StartTrigger.trigger() | nil) :: {:ok, Model.t(), []} | {:error, atom()}
  def set(document, name, trigger) do
    queue = Enum.find(document.queues, &(&1.name == name))

    cond do
      not valid?(trigger) ->
        {:error, :invalid_start_trigger}

      is_nil(queue) ->
        {:error, :not_found}

      true ->
        queues = Enum.map(document.queues, &if(&1.id == queue.id, do: %{&1 | start_trigger: trigger, generation: &1.generation + 1}, else: &1))
        {:ok, %{document | queues: queues}, []}
    end
  end

  defp valid?(trigger), do: is_nil(trigger) or trigger in Aiur.StartTrigger.triggers()
end
