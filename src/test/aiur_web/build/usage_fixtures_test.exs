defmodule AiurWeb.Build.UsageFixturesTest do
  use ExUnit.Case, async: true
  alias Aiur.BrowserHarness.FixtureBuildControl
  alias Aiur.TestSupport.BuildHome.UsageFixtures

  test "all usage blocks pass the actual payload validator" do
    dir = Path.expand("../../fixtures/build_home/usage", __DIR__)
    for file <- File.ls!(dir), do: assert({:ok, _block} = UsageFixtures.load(Path.rootname(file)))
  end

  test "control rejects unknown names and traversal (future traversal guard)" do
    for name <- ["missing", "../live"] do
      conn = Plug.Test.conn(:get, "/")
      assert %{status: 404} = FixtureBuildControl.configure(conn, %{"action" => "usage", "name" => name})
    end
  end

  test "invalid fixture cannot be broadcast" do
    dir = Path.expand("../../fixtures/build_home/usage", __DIR__)
    name = "broken-#{System.unique_integer([:positive])}"
    path = Path.join(dir, name <> ".json")
    on_exit(fn -> File.rm!(path) end)
    File.write!(path, ~s({"state":"authorized","apis":[],"providers":[]}))
    conn = FixtureBuildControl.configure(Plug.Test.conn(:get, "/"), %{"action" => "usage", "name" => name})
    assert conn.status == 422
    assert conn.resp_body =~ "usage.observed_at"
  end
end
