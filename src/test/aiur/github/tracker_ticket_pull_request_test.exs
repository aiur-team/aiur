defmodule Aiur.GitHub.TrackerTicketPullRequestTest do
  use Aiur.TestSupport
  alias Aiur.Events.GithubWebhook.Deposit
  alias Aiur.GitHub.ResourceStore
  alias Aiur.{Tracker, Workflow}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.reset()
    old = Application.get_env(:aiur, :github_transport_test_options)
    Application.put_env(:aiur, :github_transport_test_options, plug: {Req.Test, __MODULE__})
    Req.Test.stub(__MODULE__, fn _ -> flunk("PR evidence must never make a request") end)

    on_exit(fn ->
      ResourceStore.reset()
      if old, do: Application.put_env(:aiur, :github_transport_test_options, old), else: Application.delete_env(:aiur, :github_transport_test_options)
    end)

    :ok
  end

  test "a deposited closed unmerged PR reads closed, not merged, without a request" do
    deposit(%{})
    assert {:ok, %{state: :closed, merged?: false, number: 77, version: "2026-10-08T00:00:00Z"}} = Tracker.ticket_pull_request("42")
  end

  test "both merged markers prevent a merged PR being reported unmerged" do
    for markers <- [%{"merged" => true}, %{"merged_at" => "2026-10-08T00:00:00Z"}] do
      ResourceStore.reset()
      deposit(markers)
      assert {:ok, %{state: :closed, merged?: true}} = Tracker.ticket_pull_request("42")
    end
  end

  test "a newer open PR replaces closed evidence and rejects older delivery" do
    deposit(%{})
    deposit(%{"number" => 78, "state" => "open", "updated_at" => "2026-10-08T00:01:00Z"})
    deposit(%{})
    assert {:ok, %{state: :open, merged?: false, number: 78}} = Tracker.ticket_pull_request("42")
  end

  test "missing, malformed, stale and poll bodies return nil (future regression guard)" do
    assert {:ok, nil} = Tracker.ticket_pull_request("42")
    key = ResourceStore.key(:branch_pull_request, "owner", "repo", "42")

    for body <- [%{}, %{"number" => 77, "state" => "closed"}, %{"number" => 77, "state" => "closed", "merged_at" => 4}] do
      ResourceStore.reset()
      ResourceStore.put_resource(key, body, source: :webhook)
      assert {:ok, nil} = Tracker.ticket_pull_request("42")
    end

    ResourceStore.reset()
    ResourceStore.put_resource(key, body(), source: :fetch)
    assert {:ok, nil} = Tracker.ticket_pull_request("42")
    ResourceStore.reset()
    ResourceStore.put_resource(key, body(), source: :webhook)
    [{^key, entry}] = :ets.lookup(ResourceStore.Table, key)
    :ets.insert(ResourceStore.Table, {key, %{entry | fetched_at_ms: System.system_time(:millisecond) - 86_400_001}})
    assert {:ok, nil} = Tracker.ticket_pull_request("42")
    assert {:ok, nil} = Aiur.Memory.Tracker.ticket_pull_request("42")
    assert {:ok, nil} = Aiur.Linear.Tracker.ticket_pull_request("42")
  end

  defp body, do: %{"number" => 77, "state" => "closed", "merged" => false, "merged_at" => nil, "updated_at" => "2026-10-08T00:00:00Z", "head" => %{"ref" => "aiur/42-pr-evidence"}}
  defp deposit(changes), do: Deposit.deposit("pull_request", %{"action" => "closed", "pull_request" => Map.merge(body(), changes)}, "owner/repo")
end
