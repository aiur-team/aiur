defmodule Aiur.StreamdeckFleetFixture do
  @moduledoc false
  alias Aiur.AgentPubSub.FleetRefresh

  def subscription do
    topic = "streamdeck-test:#{System.unique_integer([:positive])}"
    Process.put(__MODULE__, topic)

    fn latch ->
      :ok = FleetRefresh.register(self())
      Phoenix.PubSub.subscribe(Aiur.PubSub, topic, metadata: {:fleet_refresh, latch})
    end
  end

  def broadcast_running_change(summaries), do: broadcast({:running_changed, summaries})
  def broadcast_status_change(identifier, status), do: broadcast({:status_changed, %{identifier: identifier, status: status}})

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Aiur.PubSub, Process.get(__MODULE__), message, FleetRefresh)
end
