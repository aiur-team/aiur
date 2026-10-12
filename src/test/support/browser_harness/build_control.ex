defmodule Aiur.BrowserHarness.FixtureBuildControl do
  @moduledoc false
  use Phoenix.Controller, formats: []
  import Plug.Conn
  alias Aiur.TestSupport.BuildHome.FixtureSource

  def configure(conn, %{"action" => action}) when action in ["diff", "skip"] do
    {:ok, data} = FixtureSource.full([])

    changes =
      if action == "skip" do
        %{resync: true}
      else
        row = data["sections"]["plan"] |> hd() |> Map.update!("pct", &(&1 + 1))
        %{now: data["now"], upsert: [row], remove: [], set: %{}, resync: false}
      end

    Phoenix.PubSub.broadcast(Aiur.PubSub, "build-home:fixture", {:build_changes, changes})
    send_resp(conn, 200, "build fixture control: #{action}")
  end

  def configure(conn, _params), do: send_resp(conn, 404, "unknown build fixture control action")
end
