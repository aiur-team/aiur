defmodule Aiur.Intent.WriterTest do
  use ExUnit.Case, async: true

  import Aiur.IntentFixtures

  alias Aiur.Gateway.Identity
  alias Aiur.Intent.{Hlc, Store, Writer}

  setup do
    dir = tmp_dir("intent-writer")
    {:ok, hlc} = Hlc.start_link(dir: dir, name: nil, now_fun: fn -> 5_000 end)
    {:ok, store} = Store.start_link(dir: dir, name: nil)
    {:ok, opts: [hlc: hlc, store: store, sync: :no_such_sync], store: store}
  end

  defp attrs(o \\ %{}),
    do: Map.merge(%{slot: "human", author_id: "cli:kevin", entity_kind: "ticket", entity_key: "aiur-team/aiur#7", field: "order_key", value_json: "a0"}, o)

  test "stamps the HLC, fills the origin, and lands in outbox and cache without any database", %{opts: opts, store: store} do
    assert {:ok, c} = Writer.write(attrs(), opts)
    assert {c.hlc_wall_ms, c.hlc_counter} == {5_000, 0}
    assert c.origin_gateway == Identity.current().gateway_id
    assert Store.outbox(store) == [c]
    assert Store.changes(store) == [c]
  end

  test "invalid changes write nothing and never echo the path", %{opts: opts, store: store} do
    assert {:error, :invalid_entity_key} = Writer.write(attrs(%{entity_kind: "project", entity_key: "/home/u/code/x", field: "priority"}), opts)
    assert {:error, :daemon_pause_rejected} = Writer.write(attrs(%{entity_kind: "gateway", entity_key: "g", field: "pause", slot: "default"}), opts)
    assert Store.outbox(store) == []
  end
end
