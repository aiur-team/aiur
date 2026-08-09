defmodule Aiur.AlertFeed.Backfill do
  @moduledoc false

  use GenServer

  alias Aiur.AlertFeed

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    send(self(), :backfill)
    {:ok, opts}
  end

  @impl true
  def handle_info(:backfill, opts) do
    Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> AlertFeed.backfill(opts) end)
    {:noreply, opts}
  end
end
