defmodule Aiur.GitHub.OpenIssueSnapshotTest do
  use Aiur.TestSupport
  alias Aiur.GitHub.OpenIssueSnapshot

  setup do
    OpenIssueSnapshot.reset()
    on_exit(fn -> OpenIssueSnapshot.reset() end)
    :ok
  end

  test "labels replace the latest listing and share the close signal timestamp" do
    labels = %{"7" => %{labels: ["agent:queued"], updated_at: ~U[2026-10-06 00:00:00Z]}}
    OpenIssueSnapshot.put("Owner", "Repo", [7], labels)
    assert {:ok, ^labels, taken_at} = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
    assert {:ok, numbers, ^taken_at} = OpenIssueSnapshot.fetch("owner", "repo", 60_000)
    assert numbers == MapSet.new(["7"])
    OpenIssueSnapshot.put("owner", "repo", [], %{})
    assert {:ok, labels, _} = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
    assert labels == %{}
    OpenIssueSnapshot.reset()
    assert :none = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
  end

  test "stale label observations are unavailable" do
    OpenIssueSnapshot.put("owner", "repo", [7], %{"7" => %{labels: [], updated_at: nil}})
    :ets.update_element(OpenIssueSnapshot, {:labels, "owner/repo"}, {3, System.system_time(:millisecond) - 120_000})
    assert :none = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
  end

  test "missing process returns none and does not broadcast dropped writes" do
    Phoenix.PubSub.subscribe(Aiur.PubSub, "tracker:open_issues")
    :ok = Supervisor.terminate_child(Aiur.Supervisor, OpenIssueSnapshot)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, OpenIssueSnapshot) end)
    assert :ok = OpenIssueSnapshot.put("owner", "repo", [7], %{"7" => %{labels: [], updated_at: nil}})
    assert :none = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
    refute_received {:open_issues_recorded, _}
  end
end
