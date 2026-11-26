defmodule Aiur.GitHub.OpenIssueSnapshotTest do
  use Aiur.TestSupport
  alias Aiur.GitHub.OpenIssueSnapshot

  setup do
    OpenIssueSnapshot.reset()
    on_exit(fn -> OpenIssueSnapshot.reset() end)
    :ok
  end

  test "labels retain listing start while the number snapshot records completion" do
    labels = %{"7" => %{labels: ["agent:queued"], updated_at: ~U[2026-10-06 00:00:00Z]}}
    listed_from = DateTime.add(DateTime.utc_now(), -1, :second)
    OpenIssueSnapshot.put("Owner", "Repo", [7], labels, listed_from)
    assert {:ok, ^labels, taken_at} = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
    assert taken_at == DateTime.to_unix(listed_from, :millisecond)
    assert {:ok, numbers, completed_at} = OpenIssueSnapshot.fetch("owner", "repo", 60_000)
    assert completed_at > taken_at
    assert numbers == MapSet.new(["7"])
    OpenIssueSnapshot.put("owner", "repo", [], %{}, DateTime.utc_now())
    assert {:ok, labels, _} = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
    assert labels == %{}
    OpenIssueSnapshot.reset()
    assert :none = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
  end

  test "a write without listing start retains numbers but provides no label absence evidence" do
    OpenIssueSnapshot.put("owner", "repo", [], %{})
    assert {:ok, numbers, _} = OpenIssueSnapshot.fetch("owner", "repo", 60_000)
    assert numbers == MapSet.new()
    assert :none = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
  end

  test "stale label observations are unavailable" do
    OpenIssueSnapshot.put("owner", "repo", [7], %{"7" => %{labels: [], updated_at: nil}}, DateTime.utc_now())
    :ets.update_element(OpenIssueSnapshot, {:labels, "owner/repo"}, {3, System.system_time(:millisecond) - 120_000})
    assert :none = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
  end

  test "missing process returns none and does not broadcast dropped writes" do
    Phoenix.PubSub.subscribe(Aiur.PubSub, "tracker:open_issues")
    :ok = Supervisor.terminate_child(Aiur.Supervisor, OpenIssueSnapshot)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, OpenIssueSnapshot) end)
    assert :ok = OpenIssueSnapshot.put("owner", "repo", [7], %{"7" => %{labels: [], updated_at: nil}}, DateTime.utc_now())
    assert :none = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
    refute_received {:open_issues_recorded, _}
  end
end
