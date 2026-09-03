defmodule Aiur.Events.GithubWebhook.GraphEdgeDeliveryTest do
  @moduledoc """
  `sub_issues` and `issue_dependencies` deliveries are the Build Order graph's
  two new event sources (#2313).

  Unlike every other delivery, neither publishes a fleet event: the store
  deposit is the whole point. These tests pin down that the delivery updates
  `Aiur.GitHub.ResourceStore` with the edge, that a `*_removed` delivery
  tombstones it, and that a late `added` cannot resurrect a `removed` — the
  out-of-order guarantee the store's stale-delivery guard exists to make.
  """

  use Aiur.TestSupport

  alias Aiur.Events.GithubWebhook
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Workflow

  @repo "owner/repo"
  @bot "its-applekid"

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: @repo,
      tracker_label_prefix: "aiur",
      tracker_bot_account: @bot
    )

    ResourceStore.reset()

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      if is_nil(Process.whereis(ResourceStore)) do
        Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
      end

      ResourceStore.reset()
    end)

    :ok
  end

  describe "sub_issues deliveries deposit membership edges" do
    test "a sub_issue_added delivery writes a present edge keyed parent:sub" do
      assert %{status: :dropped, reason: {:graph_event, "sub_issues", "sub_issue_added"}} =
               GithubWebhook.handle_delivery("sub_issues", sub_issue_delivery("sub_issue_added", 100, 101))

      assert {:ok, %{data: edge}} = ResourceStore.fetch(ResourceStore.key_for_repo(:sub_issue, @repo, "100:101"))
      assert %{"present" => true, "parent_issue_number" => 100, "sub_issue_number" => 101} = edge
    end

    test "a parent_issue_added delivery deposits the same canonical edge" do
      GithubWebhook.handle_delivery("sub_issues", sub_issue_delivery("parent_issue_added", 100, 102), repo: @repo)

      assert {:ok, %{data: edge}} = ResourceStore.fetch(ResourceStore.key_for_repo(:sub_issue, @repo, "100:102"))
      assert edge["present"] == true
    end

    test "a sub_issue_removed delivery tombstones the edge" do
      GithubWebhook.handle_delivery("sub_issues", sub_issue_delivery("sub_issue_added", 100, 103), repo: @repo)
      GithubWebhook.handle_delivery("sub_issues", sub_issue_delivery("sub_issue_removed", 100, 103), repo: @repo)

      assert {:ok, %{data: edge}} = ResourceStore.fetch(ResourceStore.key_for_repo(:sub_issue, @repo, "100:103"))
      assert edge["present"] == false
    end

    test "a late added cannot resurrect an edge already removed" do
      # Removed at T+1 arrives first; the older add arrives late. The store's
      # version guard must refuse the stale add, keeping the edge removed.
      later = DateTime.from_naive!(~N[2026-06-24 12:00:01], "Etc/UTC")
      earlier = DateTime.from_naive!(~N[2026-06-24 12:00:00], "Etc/UTC")

      GithubWebhook.handle_delivery("sub_issues", sub_issue_delivery("sub_issue_removed", 100, 104),
        repo: @repo,
        at: later
      )

      GithubWebhook.handle_delivery("sub_issues", sub_issue_delivery("sub_issue_added", 100, 104),
        repo: @repo,
        at: earlier
      )

      assert {:ok, %{data: edge}} = ResourceStore.fetch(ResourceStore.key_for_repo(:sub_issue, @repo, "100:104"))
      assert edge["present"] == false
    end
  end

  describe "issue_dependencies deliveries deposit dependency edges" do
    test "a blocked_by_added delivery writes a present edge keyed blocked:blocker" do
      assert %{status: :dropped, reason: {:graph_event, "issue_dependencies", "blocked_by_added"}} =
               GithubWebhook.handle_delivery(
                 "issue_dependencies",
                 dependency_delivery("blocked_by_added", 200, 201)
               )

      assert {:ok, %{data: edge}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:issue_dependency, @repo, "200:201"))

      assert %{"present" => true, "blocked_issue_number" => 200, "blocking_issue_number" => 201} = edge
    end

    test "a blocking_added delivery normalizes to the same canonical edge" do
      GithubWebhook.handle_delivery("issue_dependencies", dependency_delivery("blocking_added", 200, 202), repo: @repo)

      assert {:ok, %{data: edge}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:issue_dependency, @repo, "200:202"))

      assert edge["present"] == true
    end

    test "a blocked_by_removed delivery tombstones the edge" do
      GithubWebhook.handle_delivery("issue_dependencies", dependency_delivery("blocked_by_added", 200, 203), repo: @repo)
      GithubWebhook.handle_delivery("issue_dependencies", dependency_delivery("blocked_by_removed", 200, 203), repo: @repo)

      assert {:ok, %{data: edge}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:issue_dependency, @repo, "200:203"))

      assert edge["present"] == false
    end

    test "a late removed cannot walk back a newer add" do
      later = DateTime.from_naive!(~N[2026-06-24 12:00:01], "Etc/UTC")
      earlier = DateTime.from_naive!(~N[2026-06-24 12:00:00], "Etc/UTC")

      GithubWebhook.handle_delivery("issue_dependencies", dependency_delivery("blocked_by_added", 200, 204),
        repo: @repo,
        at: later
      )

      GithubWebhook.handle_delivery("issue_dependencies", dependency_delivery("blocked_by_removed", 200, 204),
        repo: @repo,
        at: earlier
      )

      assert {:ok, %{data: edge}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:issue_dependency, @repo, "200:204"))

      assert edge["present"] == true
    end
  end

  describe "tracked-repo resolution for edge events" do
    test "an edge delivery naming the tracked repo in its *_repo fields is tracked" do
      payload = sub_issue_delivery("sub_issue_added", 100, 105, "owner/repo")

      assert {:ok, "owner/repo"} = GithubWebhook.Normalizer.tracked_repo(payload, repo: @repo)
    end

    test "an edge delivery for an untracked repo is dropped and deposits nothing" do
      payload = sub_issue_delivery("sub_issue_added", 100, 106, "someone/else")
      assert {:drop, {:untracked_repository, "someone/else"}} = GithubWebhook.Normalizer.tracked_repo(payload, repo: @repo)
    end
  end

  describe "a graph-edge delivery never publishes a fleet event" do
    test "the normalizer drops it with a graph_event reason, so nothing wakes an agent" do
      assert %{status: :dropped, reason: {:graph_event, "sub_issues", "sub_issue_added"}} =
               GithubWebhook.handle_delivery("sub_issues", sub_issue_delivery("sub_issue_added", 100, 107), repo: @repo)

      assert %{status: :dropped, reason: {:graph_event, "issue_dependencies", "blocked_by_removed"}} =
               GithubWebhook.handle_delivery(
                 "issue_dependencies",
                 dependency_delivery("blocked_by_removed", 200, 205),
                 repo: @repo
               )
    end
  end

  defp sub_issue_delivery(action, parent, sub, repo \\ @repo) do
    %{
      "action" => action,
      "parent_issue_id" => "DI_parent_#{parent}",
      "parent_issue_number" => parent,
      "parent_issue_repo" => repo,
      "sub_issue_id" => "DI_sub_#{sub}",
      "sub_issue_number" => sub,
      "sub_issue_repo" => repo,
      "sender" => %{"login" => @bot}
    }
  end

  defp dependency_delivery(action, blocked, blocker, repo \\ @repo) do
    %{
      "action" => action,
      "blocked_issue_id" => "DI_blocked_#{blocked}",
      "blocked_issue_number" => blocked,
      "blocked_issue_repo" => repo,
      "blocking_issue_id" => "DI_blocker_#{blocker}",
      "blocking_issue_number" => blocker,
      "blocking_issue_repo" => repo,
      "sender" => %{"login" => @bot}
    }
  end
end
