defmodule AiurWeb.Streamdeck.Deck.BuildOrder do
  @moduledoc "Focus build lane in the shared queue panel's ordering."

  alias AiurWeb.EndpointConfig

  @spec read(keyword()) :: map()
  def read(_opts \\ []) do
    read = EndpointConfig.get(:streamdeck_build_queue_fun) || (&Aiur.BuildQueue.show/0)
    project(read.())
  end

  defp project(%{status: :running, queues: queues}) do
    lane =
      queues
      |> Enum.filter(fn queue -> is_integer(queue.progress.total) and queue.progress.total > 0 end)
      |> Enum.min_by(&{&1.set_rank, &1.queue_id}, fn -> nil end)

    case lane do
      nil -> %{build: nil, build_status: "none"}
      queue -> %{build: build(queue), build_status: "ok"}
    end
  end

  defp project(_unavailable), do: %{build: nil, build_status: "unavailable"}

  defp build(queue) do
    queue
    |> Map.take([:queue_id, :name, :kind])
    |> Map.merge(Map.take(queue.progress, [:completed, :resolved, :total, :percent, :resolution]))
    |> Map.put(:eta_seconds, nil)
  end
end
