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
end
