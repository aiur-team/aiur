defmodule Aiur.GitHub.PullRequestHeadUpdateTest do
  use Aiur.TestSupport

  alias Aiur.Events.GithubWebhook.Deposit
  alias Aiur.GitHub.{PollSnapshots, ResourceStore}
  alias Aiur.{Tracker, Workflow}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.reset()
    on_exit(fn -> ResourceStore.reset() end)
    :ok
  end

  test "opened and synchronize deliveries project their actual head update timestamp" do
    for action <- ["opened", "synchronize"] do
      ResourceStore.reset()
      at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      deposit(action, body("sha-1", at))
      assert {:ok, %{head_sha: "sha-1", head_updated_at: ^at}} = Tracker.ticket_pull_request("42")
      assert {:ok, %{data: %{"head_updated_at" => ^at}}} = ResourceStore.fetch(key(:pull_request, 77))
    end
  end

  test "unrelated same-head deliveries preserve the push time without relabeling review time" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    pushed = DateTime.to_iso8601(now)
    reviewed = now |> DateTime.add(10) |> DateTime.to_iso8601()
    deposit("synchronize", body("sha-1", pushed))
    Deposit.deposit("pull_request_review", %{"action" => "submitted", "pull_request" => body("sha-1", reviewed)}, "owner/repo")
    assert {:ok, %{head_updated_at: ^pushed, version: ^reviewed}} = Tracker.ticket_pull_request("42")
  end

  test "a head change without synchronize removes the former head's timestamp" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    deposit("synchronize", body("sha-1", DateTime.to_iso8601(now)))
    deposit("edited", body("sha-2", now |> DateTime.add(10) |> DateTime.to_iso8601()))
    assert {:ok, %{head_sha: "sha-2", head_updated_at: nil}} = Tracker.ticket_pull_request("42")
  end

  test "poll facts preserve timestamps for the same head and clear them for a changed head" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    pushed = DateTime.to_iso8601(now)
    deposit("synchronize", body("sha-1", pushed))
    assert :ok = PollSnapshots.put_executor_sweep_pr("owner/repo", "42", body("sha-1", now |> DateTime.add(10) |> DateTime.to_iso8601()))
    assert {:ok, %{data: %{"head_updated_at" => ^pushed}}} = ResourceStore.fetch(key(:branch_pull_request, "42"))
    assert :ok = PollSnapshots.put_executor_sweep_pr("owner/repo", "42", body("sha-2", now |> DateTime.add(20) |> DateTime.to_iso8601()))
    assert {:ok, %{data: changed}} = ResourceStore.fetch(key(:branch_pull_request, "42"))
    refute Map.has_key?(changed, "head_updated_at")
  end

  defp deposit(action, pr), do: Deposit.deposit("pull_request", %{"action" => action, "pull_request" => pr}, "owner/repo")
  defp key(type, id), do: ResourceStore.key(type, "owner", "repo", id)
  defp body(sha, at), do: %{"number" => 77, "state" => "open", "merged" => false, "merged_at" => nil, "updated_at" => at, "head" => %{"ref" => "aiur/42-head-time", "sha" => sha}}
end
