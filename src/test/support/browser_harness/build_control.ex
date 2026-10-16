defmodule Aiur.BrowserHarness.FixtureBuildControl do
  @moduledoc false
  use Phoenix.Controller, formats: []
  import Plug.Conn
  alias Aiur.TestSupport.BuildHome.{EarlierControl, FixtureSource}

  def configure(conn, %{"action" => action} = params) when action in ["diff", "skip"] do
    conn = fetch_query_params(conn)
    params = Map.merge(params, conn.query_params)
    {:ok, data} = FixtureSource.full([])

    changes =
      cond do
        action == "skip" ->
          %{resync: true}

        params["name"] in ~w(card-pct-null card-clock-3h) ->
          named_diff(params["name"])

        true ->
          row = change_row(data, params)
          %{now: data["now"], upsert: [row], remove: [], set: %{}, resync: false}
      end

    Phoenix.PubSub.broadcast(Aiur.PubSub, "build-home:fixture", {:build_changes, changes})
    send_resp(conn, 200, "build fixture control: #{action}")
  end

  def configure(conn, %{"action" => "earlier"} = params) do
    conn = fetch_query_params(conn)
    EarlierControl.configure(Map.merge(params, conn.query_params))
    send_resp(conn, 200, "earlier configured")
  end

  def configure(conn, _params), do: send_resp(conn, 404, "unknown build fixture control action")

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
