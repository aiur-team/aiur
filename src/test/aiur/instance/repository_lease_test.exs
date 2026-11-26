defmodule Aiur.Instance.RepositoryLeaseTest do
  use ExUnit.Case, async: true

  alias Aiur.Instance.LeaseStore.RepositoryLease

  test "claim and renew use the instance id carried by the store message" do
    test_pid = self()

    query_fun = fn _connection, sql, params, _opts ->
      send(test_pid, {:repository_lease_query, sql, params})
      {:ok, %{num_rows: 1}}
    end

    state = %{
      conn: :test_connection,
      instance_id: fn -> flunk("query must use the message instance id") end,
      query_fun: query_fun,
      leases: MapSet.new(),
      opts: [],
      reconnect_ms: 1_000,
      reconnect_max_ms: 30_000,
      outage?: false,
      retry_timer: nil
    }

    assert :acquired = RepositoryLease.handle(state, :claim, "owner/repo", 30_000, "instance-a")
    assert_receive {:repository_lease_query, claim_sql, ["owner/repo", "instance-a", 30.0]}, 100
    assert claim_sql =~ "INSERT INTO aiur_repository_leases"

    assert :ok = RepositoryLease.handle(state, :renew, "owner/repo", 30_000, "instance-a")
    assert_receive {:repository_lease_query, renew_sql, ["owner/repo", "instance-a", 30.0]}, 100
    assert renew_sql =~ "UPDATE aiur_repository_leases"
  end
end
