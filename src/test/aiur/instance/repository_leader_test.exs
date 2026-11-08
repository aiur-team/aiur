defmodule Aiur.Instance.RepositoryLeaderTest do
  use ExUnit.Case, async: true

  alias Aiur.Instance.RepositoryLeader

  test "status preserves unavailable and unheld lease states with an observation time" do
    now = DateTime.utc_now()

    unknown = RepositoryLeader.status(now, repository: "owner/repo", leader_fun: fn _ -> :unknown end)
    none = RepositoryLeader.status(now, repository: "owner/repo", leader_fun: fn _ -> :unheld end)

    assert unknown == %{leader: "unknown", lease_age: "unknown", observed_at: now, freshness: :fresh}
    assert none == %{leader: "none", lease_age: "unknown", observed_at: now, freshness: :fresh}
  end

  # Guard: passes on main (MPG-108 research row 16); a secondary must never start leader services.
  test "guard: a secondary without a lease store starts no leader services" do
    parent = self()
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: :"leader_guard_#{System.unique_integer([:positive])}"})
    service = Supervisor.child_spec({Agent, fn -> send(parent, :service_started) end}, id: :guarded)

    start_supervised!(
      {RepositoryLeader,
       name: :"leader_guard_server_#{System.unique_integer([:positive])}",
       role: "secondary",
       repository: "owner/repo",
       store_configured_fun: fn -> false end,
       services: [service],
       supervisor: supervisor,
       interval_ms: 60_000}
    )

    refute_receive :service_started, 100
    assert DynamicSupervisor.which_children(supervisor) == []
  end
end
