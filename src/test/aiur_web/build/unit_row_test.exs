defmodule AiurWeb.Build.UnitRowTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias AiurWeb.Build.{Index, IndexReader, IndexSource, Payload}

  test "catalog rows stay private and are read by id from the real index" do
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "NODE-12", "number" => 12}, {"acme", "widgets"}, {"acme", "widgets"})
    row = %{identity: identity, runtime: %{bucket: :running, work_state: :working}, timestamps: %{started_at: DateTime.utc_now()}}
    foreign = %{row | identity: %{identity | owner: "another", identifier: "13"}}
    catalog = %{status: :ready, snapshot: %{rows: [row, foreign]}}
    read = fn _, _, _ -> IndexReader.read(MapSet.new([:now]), parts(), units_fun: fn -> catalog end) end
    server = start_supervised!({Index, name: nil, subscribe: fn -> :ok end, read: read, daemon_read: fn _ -> nil end, daemon_timer: fn _, _, _ -> make_ref() end})
    assert {:ok, data} = Index.window(server, "Etc/UTC")
    assert {:ok, ^row} = IndexSource.unit_row("12", server: server)
    assert {:error, :not_found} = IndexSource.unit_row("13", server: server)
    assert {:error, :not_found} = IndexSource.unit_row("999", server: server)
    encoded = data |> Payload.snapshot("epoch", 0) |> Jason.encode!()
    refute encoded =~ "unit_rows"
    refute encoded =~ "NODE-12"
  end

  test "stale catalogs fail closed rather than serving an eligible cached control" do
    p = parts()
    p = put_in(p.now, %{rows: %{}, source: %{state: "stale", observed_at: nil, reason: "held"}, unit_rows: %{"12" => %{runtime: %{work_state: :working}}}})
    server = start_supervised!({Index, name: nil, subscribe: fn -> :ok end, read: fn _, _, _ -> p end, daemon_read: fn _ -> nil end, daemon_timer: fn _, _, _ -> make_ref() end})
    assert {:ok, _data} = Index.window(server, "Etc/UTC")
    assert {:error, :not_found} = IndexSource.unit_row("12", server: server)
  end
end
