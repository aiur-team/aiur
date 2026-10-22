defmodule Aiur.BrowserHarness.FixtureBuildControl do
  @moduledoc false
  use Phoenix.Controller, formats: []
  import Plug.Conn
  plug(:fetch_query_params)
  alias Aiur.TestSupport.BuildHome.{EarlierControl, FixtureSource, UsageFixtures}

  def configure(conn, %{"action" => "stream", "key" => key}) do
    conn |> put_session("build_stream", key) |> send_resp(200, "build fixture stream: #{key}")
  end

  def configure(conn, %{"action" => action} = params) when action in ["diff", "skip"] do
    conn = fetch_query_params(conn)
    params = Map.merge(params, conn.query_params)
    {:ok, data} = FixtureSource.full([])

    changes =
      if action == "skip" do
        %{resync: true}
      else
        diff_changes(data, params)
      end

    Phoenix.PubSub.broadcast(Aiur.PubSub, FixtureSource.topic(get_session(conn, "build_stream")), {:build_changes, changes})
    send_resp(conn, 200, "build fixture control: #{action}")
  end

  def configure(conn, %{"action" => "usage", "name" => name}) do
    case UsageFixtures.load(name) do
      {:ok, block} ->
        {:ok, data} = FixtureSource.full([])
        Phoenix.PubSub.broadcast(Aiur.PubSub, FixtureSource.topic(get_session(conn, "build_stream")), {:build_changes, %{now: data["now"], upsert: [], remove: [], set: %{usage: block}}})
        send_resp(conn, 200, "build fixture control: usage")

      {:error, {:invalid, errors}} ->
        send_resp(conn, 422, inspect(errors))

      {:error, :not_found} ->
        send_resp(conn, 404, "unknown usage fixture")
    end
  end

  def configure(conn, %{"action" => "earlier"} = params) do
    conn = fetch_query_params(conn)
    EarlierControl.configure(Map.merge(params, conn.query_params))
    send_resp(conn, 200, "earlier configured")
  end

  def configure(conn, _params), do: send_resp(conn, 404, "unknown build fixture control action")

  defp diff_changes(_data, %{"name" => name})
       when name in ~w(card-pct-null card-clock-3h plan-new-epic hist-new-epic counts-changed counts-unknown edge-state-cleared edge-unknown chain-add-dep chain-remove-root daemon-unknown offline-no-heartbeat agents-unavailable agents-stale agent-state-null add-four-agents),
       do: named_diff(name)

  defp diff_changes(data, %{"name" => "queue-unavailable"}) do
    path = Path.expand("../../fixtures/build_home/diffs/queue-unavailable.json", __DIR__)
    set = path |> File.read!() |> Jason.decode!()
    %{now: data["now"], upsert: [], remove: [], set: set, resync: false}
  end

  defp diff_changes(data, %{"name" => "sources-ok"}) do
    %{now: data["now"], upsert: [], remove: [], set: %{"sources" => data["sources"]}, resync: false}
  end

  defp diff_changes(data, params) do
    %{now: data["now"], upsert: [change_row(data, params)], remove: [], set: %{}, resync: false}
  end

  defp named_diff(name) do
    path = Path.expand("../../fixtures/build_home/diffs/#{name}.json", __DIR__)
    data = path |> File.read!() |> Jason.decode!()
    %{now: data["now"], upsert: data["upsert"], remove: data["remove"], set: data["set"], resync: false}
  end

  defp change_row(data, params) do
    row = Enum.find(List.flatten(Map.values(data["sections"])), &(&1["id"] == params["id"])) || hd(data["sections"]["plan"])

    case params["op"] do
      "move" ->
        section = if params["to"] in ~w(hist now plan nq), do: params["to"], else: row["sec"]
        row |> Map.put("sec", section) |> Map.put("end", data["now"]) |> Map.put("cue", if(section == "plan", do: hd(data["sections"]["plan"])["cue"]))

      "title" ->
        Map.update!(row, "title", &(&1 <> " updated"))

      _ ->
        Map.update!(row, "pct", &(&1 + 1))
    end
  end
end

defmodule Aiur.BrowserHarness.FixtureLiveSocket do
  @moduledoc """
  LiveView socket that registers a page's transport under its `build_stream`
  session key, so `/build-control` diffs from one Playwright worker reach only
  that worker's build page.
  """
  use Phoenix.LiveView.Socket

  def connect(_params, socket, info) do
    if stream = info[:session]["build_stream"], do: Registry.register(Aiur.TestSupport.BuildHome.FixtureSource.Streams, stream, nil)
    {:ok, socket}
  end
end
