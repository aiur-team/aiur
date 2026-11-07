defmodule Aiur.Intent.PostgresTest do
  # Runs in the pre-handoff action against PostgreSQL (AIUR_LEASE_DATABASE_URL); skipped when unset.
  use ExUnit.Case, async: false

  import Aiur.IntentFixtures

  alias Aiur.Instance.LeaseStore
  alias Aiur.Instance.LeaseStore.Postgres
  alias Aiur.Intent.Change

  @moduletag skip: is_nil(System.get_env("AIUR_LEASE_DATABASE_URL"))

  setup do
    url = System.get_env("AIUR_LEASE_DATABASE_URL") || flunk("CI must configure AIUR_LEASE_DATABASE_URL for this integration test")
    previous = Application.get_env(:aiur, :lease_database_url)
    Application.put_env(:aiur, :lease_database_url, url)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :lease_database_url, previous),
        else: Application.delete_env(:aiur, :lease_database_url)
    end)

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({LeaseStore, name: name, url: url, instance_id: "intent-#{System.unique_integer([:positive])}"})
    {:ok, server: name, url: url}
  end

  defp publish_many(server, count) do
    for batch <- Enum.chunk_every(1..count, 100) do
      changes = Enum.map(batch, &change(%{hlc_counter: &1}))
      assert {:ok, _} = LeaseStore.publish_intent_changes(changes, server: server)
      changes
    end
    |> List.flatten()
  end

  test "publishing the same change twice stores one row and it pulls back intact", %{server: server} do
    c = change(%{value_json: %{"k" => 1}})
    assert {:ok, [id]} = LeaseStore.publish_intent_changes([c], server: server)
    assert {:ok, [^id]} = LeaseStore.publish_intent_changes([c], server: server)
    assert id == c.change_id

    assert {:ok, rows} = LeaseStore.intent_changes_since(0, 100_000, server: server)
    assert [row] = Enum.filter(rows, &(&1.change_id == c.change_id))
    assert %{value_json: %{"k" => 1}, slot: "human", seq: seq} = row
    assert is_integer(seq)
  end

  test "create_tables is idempotent", %{url: url} do
    {:ok, conn} = Postgrex.start_link(Postgres.connection_opts(url))
    assert :ok = Postgres.create_tables(conn)
    assert :ok = Postgres.create_tables(conn)
  end

  test "the database rejects an unknown slot", %{url: url} do
    {:ok, conn} = Postgrex.start_link(Postgres.connection_opts(url))

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Postgrex.query(
               conn,
               "INSERT INTO aiur_intent_changes (change_id, hlc_wall_ms, hlc_counter, origin_gateway, slot, author_id, entity_kind, entity_key, field, value_json) VALUES ($1, 1, 0, 'g', 'robot', 'a', 'ticket', 'o/r#1', 'order_key', '\"a\"')",
               [Change.uuid_to_binary(Change.new_id())]
             )
  end

  test "paging past one page never repeats or skips rows", %{server: server} do
    publish_many(server, 1_200)
    assert {:ok, page1} = LeaseStore.intent_changes_since(0, 500, server: server)
    cursor1 = page1 |> List.last() |> Map.fetch!(:seq)
    assert {:ok, page2} = LeaseStore.intent_changes_since(cursor1, 500, server: server)
    assert length(page1) == 500 and length(page2) == 500
    assert Enum.min_by(page2, & &1.seq).seq > cursor1
    assert page1 |> Enum.map(& &1.seq) |> Enum.concat(Enum.map(page2, & &1.seq)) |> Enum.uniq() |> length() == 1_000
  end

  test "a row at or below the cursor is returned only with the overlap, once", %{server: server} do
    [first | _] = publish_many(server, 2)
    assert {:ok, rows} = LeaseStore.intent_changes_since(0, 100_000, server: server)
    cursor = rows |> List.last() |> Map.fetch!(:seq)

    assert {:ok, without} = LeaseStore.intent_changes_since(cursor, 500, server: server)
    assert without == []

    assert {:ok, with_overlap} = LeaseStore.intent_changes_since(cursor, 500, server: server, overlap: true)
    assert first.change_id in Enum.map(with_overlap, & &1.change_id)
    assert Enum.all?(with_overlap, &(&1.seq <= cursor))
  end
end
