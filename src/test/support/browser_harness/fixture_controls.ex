defmodule Aiur.BrowserHarness.FixtureBuildDataset do
  @moduledoc false

  use Phoenix.Controller, formats: []

  alias Aiur.TestSupport.BuildHome.FixtureSource

  def configure(conn, %{"dataset" => dataset}) do
    if dataset in FixtureSource.datasets() do
      Application.put_env(:aiur, :build_fixture_dataset, dataset)
      query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
      redirect(conn, to: "/build" <> query)
    else
      conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(404, "unknown build fixture dataset")
    end
  end
end

defmodule Aiur.BrowserHarness.FixtureStreamdeckControl do
  @moduledoc """
  Lets one browser spec opt its own fixture server into a writable dashboard.

  Stream Deck key presses only reach the agent control facade when the
  dashboard is writable, so the operator-flow spec needs that gate open to
  prove a pause actually pauses. Every `run-browser-tests.mjs` invocation gets
  its own fixture server, so flipping it here cannot leak into another spec.
  """

  use Phoenix.Controller, formats: []

  import Plug.Conn

  alias Aiur.BrowserHarness.FixtureServer

  @modes %{"writable" => true, "read_only" => false}

  def configure(conn, %{"mode" => mode}) when is_map_key(@modes, mode) do
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, Map.fetch!(@modes, mode))
    FixtureServer.reset_streamdeck_pauses()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "streamdeck fixture control: #{mode}")
  end

  def configure(conn, _params), do: send_resp(conn, 404, "unknown streamdeck fixture control mode")
end
