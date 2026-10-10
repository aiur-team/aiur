defmodule Aiur.AlertFeed.Backfill do
  @moduledoc false

  use GenServer

  alias Aiur.AlertFeed
  alias Aiur.Alerts.StaleNotClosed

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    send(self(), :backfill)
    {:ok, opts}
  end

  @impl true
  def handle_info(:backfill, opts) do
    Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
      AlertFeed.backfill(opts)
      reconcile_stale_not_closed()
    end)

    {:noreply, opts}
  end

  # #3943: resolve false "ticket was not closed" alerts for tickets closed done.
  defp reconcile_stale_not_closed do
    if Aiur.Orchestrator.Dispatcher.github_tracker_kind?(), do: StaleNotClosed.reconcile(&StaleNotClosed.done_ids/1)
  catch
    _kind, _reason -> :ok
  end
end
