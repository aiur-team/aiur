defmodule Aiur.Intent.PostgresTest do
  # Needs AIUR_LEASE_DATABASE_URL (the CI job that sets it runs this); skipped otherwise.
  use ExUnit.Case, async: false

  import Aiur.IntentFixtures

  alias Aiur.Instance.LeaseStore

  @moduletag skip: is_nil(System.get_env("AIUR_LEASE_DATABASE_URL"))

  setup do
    url = System.get_env("AIUR_LEASE_DATABASE_URL")
    previous = Application.get_env(:aiur, :lease_database_url)
    Application.put_env(:aiur, :lease_database_url, url)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :lease_database_url, previous),
        else: Application.delete_env(:aiur, :lease_database_url)
    end)

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, pid} = LeaseStore.start_link(name: name, url: url, instance_id: "intent-#{System.unique_integer([:positive])}")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, server: name}
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
end
