defmodule Aiur.Config.ServerDashboardOriginsTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema.Server

  defp cs(origins), do: Server.changeset(%Server{}, %{"dashboard_origins" => origins})

  test "normalises, dedupes, and rejects non-origins" do
    assert Ecto.Changeset.get_field(cs(["https://A.ts.net/", "https://a.ts.net"]), :dashboard_origins) == ["https://a.ts.net"]
    assert cs(["http://localhost:4001"]).valid?

    for bad <- ["*", "https://a.ts.net/x", "http://a.ts.net", "https://u@a.ts.net", "https://a.ts.net?x=1"] do
      refute cs([bad]).valid?, bad
    end
  end
end
