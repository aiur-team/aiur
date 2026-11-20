defmodule Aiur.BrowserHarness.StreamdeckTicket do
  @moduledoc false
  alias Aiur.BrowserHarness.FixtureServer

  def ticket(id, _) do
    {:ok, %{title: "Fixture ticket #{id}", pr: nil}}
  end

  def unit_row(id, _) do
    snapshot = FixtureServer.streamdeck_snapshot()
    agent = Enum.find(snapshot.running ++ snapshot.idle ++ snapshot.retrying, &(to_string(&1.identifier) == id))
    paused = agent && (agent[:work_state] == :paused or agent[:tracker_paused] == true)

    {:ok,
     %{
       identity: %Aiur.TrackerIdentity{status: :joinable, kind: :github, owner: "acme", repository: "aiur", provider_id: "node", database_id: 1, identifier: id},
       lifecycle: :active,
       terminal?: false,
       replacement_boundary?: false,
       reasons: %{pause: nil},
       runtime: %{bucket: if(paused, do: :paused, else: :running), work_state: if(paused, do: :paused, else: :working), tracker_paused?: false}
     }}
  end
end
