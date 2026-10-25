defmodule Aiur.Events.GithubWebhook.DepositIssueBodiesTest do
  @moduledoc """
  What an issue or graph-edge delivery deposits, and what a deletion or refusal leaves behind.

  Split out of `deposit_test.exs`, whose moduledoc states what these suites
  assert and why.
  """

  use Aiur.TestSupport.DepositCase

  alias Aiur.Events.GithubWebhook
  alias Aiur.GitHub.{DependenciesApi, ResourceStore}

  @repo "owner/repo"

  describe "delivery types that deposit bodies" do
    test "issues deposits the issue and label set even though the event only reconciles" do
      number = ticket_number()

      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", issues_delivery("labeled"), repo: @repo, reconcile_fun: fn _ -> :ok end)

      assert {:ok, %{data: %{"number" => ^number}}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue, @repo, number))
      assert {:ok, %{data: [_label]}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_labels, @repo, number))
    end

    # Acceptance #2313: a `sub_issues` delivery carries one parent↔sub-issue
    # edge, and the Build Order catalog rebuilds each root's membership from the
    # store rather than polling GitHub. The edge is deposited keyed by the
    # `"parent:sub"` number pair, with `present` holding the operation and the
    # delivery's arrival time as its ordering version.
    test "sub_issues sub_issue_added deposits the edge keyed parent:sub" do
      ticket = ticket_id()
      number = ticket_number()
      fixture_value0 = "#{ticket}:21"
      GithubWebhook.handle_delivery("sub_issues", sub_issue_added_delivery(), repo: @repo)

      key = ResourceStore.key_for_repo(:sub_issue, @repo, fixture_value0)
      assert {:ok, %{data: data, source: :webhook}} = ResourceStore.fetch(key)
      assert data["present"] == true
      assert data["parent_issue_number"] == number
      assert data["sub_issue_number"] == 21
    end

    test "sub_issues sub_issue_removed tombstones the edge" do
      ticket = ticket_id()
      fixture_value0 = "#{ticket}:21"
      GithubWebhook.handle_delivery("sub_issues", sub_issue_added_delivery(), repo: @repo)
      key = ResourceStore.key_for_repo(:sub_issue, @repo, fixture_value0)
      assert {:ok, %{data: %{"present" => true}}} = ResourceStore.fetch(key)

      GithubWebhook.handle_delivery("sub_issues", sub_issue_removed_delivery(), repo: @repo)
      assert {:ok, %{data: %{"present" => false}}} = ResourceStore.fetch(key)
    end

    # Acceptance #2313: a blocked-by relationship added outside Aiur is likewise
    # reflected. The `issue_dependencies` delivery carries the edge facts and
    # the deposit writes the canonical `"blocked:blocker"` edge the catalog
    # reads, tombstoned by a `*_removed` action.
    test "issue_dependencies blocked_by_added deposits the edge keyed blocked:blocker" do
      ticket = ticket_id()
      number = ticket_number()
      fixture_value0 = "#{ticket}:99"
      GithubWebhook.handle_delivery("issue_dependencies", dependency_created_delivery(), repo: @repo)

      key = ResourceStore.key_for_repo(:issue_dependency, @repo, fixture_value0)
      assert {:ok, %{data: data, source: :webhook}} = ResourceStore.fetch(key)
      assert data["present"] == true
      assert data["blocked_issue_number"] == number
      assert data["blocking_issue_number"] == 99
    end

    test "issue_dependencies blocked_by_removed tombstones the edge" do
      ticket = ticket_id()
      fixture_value0 = "#{ticket}:99"
      GithubWebhook.handle_delivery("issue_dependencies", dependency_created_delivery(), repo: @repo)
      key = ResourceStore.key_for_repo(:issue_dependency, @repo, fixture_value0)
      assert {:ok, %{data: %{"present" => true}}} = ResourceStore.fetch(key)

      GithubWebhook.handle_delivery("issue_dependencies", dependency_removed_delivery(), repo: @repo)
      assert {:ok, %{data: %{"present" => false}}} = ResourceStore.fetch(key)
    end

    test "pull_request_review_thread deposits the pull request under both keys" do
      number = ticket_number()
      keys = GithubWebhook.Deposit.deposit("pull_request_review_thread", pull_request_review_thread_delivery(), @repo)

      assert ResourceStore.key_for_repo(:pull_request, @repo, 77) in keys
      assert ResourceStore.key_for_repo(:branch_pull_request, @repo, number) in keys

      assert {:ok, %{data: %{"number" => 77}, source: :webhook}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:pull_request, @repo, 77))
    end

    test "sub_issues deposits the sub-issue and the parent issue" do
      number = ticket_number()
      GithubWebhook.handle_delivery("sub_issues", sub_issues_delivery(), repo: @repo)

      assert {:ok, %{data: %{"number" => 41}}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue, @repo, 41))
      assert {:ok, %{data: %{"number" => ^number}}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue, @repo, number))
      assert {:ok, %{data: [_label]}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_labels, @repo, 41))
    end

    test "issue_dependencies deposits the issue; a lone blocked_by_added invents no blocker list" do
      number = ticket_number()
      GithubWebhook.handle_delivery("issue_dependencies", issue_dependencies_delivery(), repo: @repo)

      assert {:ok, %{data: %{"number" => ^number}}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue, @repo, number))

      # The delivery names one edge, which is not a complete answer: the store
      # must not fabricate a `:issue_blocked_by` list from it (review #2332), so
      # a cold entry stays absent and the reader pays for the full list.
      assert :miss = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_blocked_by, @repo, number))
    end

    test "blocked_by_added merges into an existing blocker list rather than replacing it" do
      number = ticket_number()
      key = ResourceStore.key_for_repo(:issue_blocked_by, @repo, number)

      # The baseline a full `GET blocked_by` 200 writes: a complete list the
      # reader already holds, which is the only shape a merge may grow.
      ResourceStore.put_resource(key, [%{"id" => 90_001, "number" => 90}], source: :fetch, etag: ~s("base"))

      GithubWebhook.handle_delivery("issue_dependencies", issue_dependencies_delivery(), repo: @repo)

      assert {:ok, %{data: blockers}} = ResourceStore.fetch(key)
      assert Enum.map(blockers, & &1["number"]) |> Enum.sort() == [80, 90]
    end

    test "a second issue_dependencies edge merges into the held blocker list rather than replacing it" do
      number = ticket_number()
      key = ResourceStore.key_for_repo(:issue_blocked_by, @repo, number)
      ResourceStore.put_resource(key, [], source: :fetch, etag: ~s("base"))

      GithubWebhook.handle_delivery("issue_dependencies", issue_dependencies_delivery(), repo: @repo)
      second = %{issue_dependencies_delivery() | "blocked_by_issue" => %{"id" => 90_001, "number" => 90}}

      GithubWebhook.handle_delivery("issue_dependencies", second, repo: @repo)

      assert {:ok, %{data: blockers}} = ResourceStore.fetch(key)
      assert Enum.map(blockers, & &1["number"]) |> Enum.sort() == [80, 90]
    end

    test "blocked_by_removed drops the held blocker list rather than merging the edge in" do
      number = ticket_number()
      key = ResourceStore.key_for_repo(:issue_blocked_by, @repo, number)
      ResourceStore.put_resource(key, [%{"id" => 80_001, "number" => 80}], source: :fetch, etag: ~s("base"))

      removal = %{issue_dependencies_delivery() | "action" => "blocked_by_removed"}

      GithubWebhook.handle_delivery("issue_dependencies", removal, repo: @repo)

      # The death of the edge invalidates the whole held list: the next
      # `fetch_blocked_by` pays for the truth instead of serving a stale answer.
      assert :miss = ResourceStore.fetch(key)
    end

    test "a lone blocked_by_removed on a cold entry fabricates nothing" do
      number = ticket_number()
      key = ResourceStore.key_for_repo(:issue_blocked_by, @repo, number)
      removal = %{issue_dependencies_delivery() | "action" => "blocked_by_removed"}

      GithubWebhook.handle_delivery("issue_dependencies", removal, repo: @repo)

      # The old code merged the delivery's edge in regardless of action, so a
      # removal announced the death of an edge and then re-added it (review
      # #2332, Probe B). A removal must never write.
      assert :miss = ResourceStore.fetch(key)
    end

    # The deposit→read link the reachability table only proves by key equality:
    # a webhook `blocked_by_added` onto a held list is served by the next
    # `fetch_blocked_by` with zero upstream calls (review #2332, structural gap).
    test "a webhook blocked_by_added onto a held list is served by the next fetch_blocked_by" do
      number = ticket_number()
      key = ResourceStore.key_for_repo(:issue_blocked_by, @repo, number)
      ResourceStore.put_resource(key, [%{"id" => 90_001, "number" => 90}], source: :fetch, etag: ~s("base"))

      GithubWebhook.handle_delivery("issue_dependencies", issue_dependencies_delivery(), repo: @repo)

      assert {:ok, blockers} =
               DependenciesApi.fetch_blocked_by(number,
                 request_fun: fn _request -> flunk("the merged list must be served, not fetched") end
               )

      assert Enum.map(blockers, & &1["number"]) |> Enum.sort() == [80, 90]
    end

    test "a delivery for an untracked repository deposits nothing" do
      GithubWebhook.handle_delivery(
        "issue_comment",
        %{issue_comment_delivery(9205) | "repository" => %{"full_name" => "someone/else"}},
        repo: @repo
      )

      assert :miss = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_comment, "someone/else", 9205))
      assert :miss = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_comment, @repo, 9205))
    end

    test "a deleted comment drops the held body rather than serving a stale one" do
      GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9206), repo: @repo)
      key = ResourceStore.key_for_repo(:issue_comment, @repo, 9206)
      assert {:ok, _entry} = ResourceStore.fetch(key)

      GithubWebhook.handle_delivery(
        "issue_comment",
        %{issue_comment_delivery(9206) | "action" => "deleted"},
        repo: @repo
      )

      assert :miss = ResourceStore.fetch(key)
    end

    test "deleting a comment keeps the issue the same delivery carried" do
      number = ticket_number()
      # The action belongs to the comment. Letting it reach the issue would throw
      # away a cached issue body using a delivery that is holding a current one.
      GithubWebhook.handle_delivery(
        "issue_comment",
        %{issue_comment_delivery(9207) | "action" => "deleted"},
        repo: @repo
      )

      assert :miss = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_comment, @repo, 9207))
      assert {:ok, %{data: %{"number" => ^number}}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue, @repo, number))
      assert {:ok, %{data: [_label]}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_labels, @repo, number))
    end

    test "a deleted issue takes its label set with it" do
      number = ticket_number()
      GithubWebhook.handle_delivery("issues", issues_delivery("labeled"), repo: @repo, reconcile_fun: fn _ -> :ok end)
      assert {:ok, _entry} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_labels, @repo, number))

      GithubWebhook.handle_delivery("issues", issues_delivery("deleted"), repo: @repo, reconcile_fun: fn _ -> :ok end)

      # An issue body nothing holds beside a label set something does would be an
      # entry that contradicts itself.
      assert :miss = ResourceStore.fetch(ResourceStore.key_for_repo(:issue, @repo, number))
      assert :miss = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_labels, @repo, number))
    end

    test "a dismissed review is deposited without claiming an unchanged version" do
      GithubWebhook.handle_delivery("pull_request_review", review_delivery(9208), repo: @repo)

      dismissed =
        9208
        |> review_delivery()
        |> Map.put("action", "dismissed")
        |> put_in(["review", "state"], "dismissed")

      GithubWebhook.handle_delivery("pull_request_review", dismissed, repo: @repo)

      # `submitted_at` does not move on a dismissal and a REST review has no
      # `updated_at`, so filing the changed body under the submission marker
      # would tell the next reader nothing had changed.
      assert {:ok, %{data: %{"state" => "DISMISSED"}, version: nil}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:pr_review, @repo, 9208))
    end

    test "a body the store cannot hold is a miss, not a half-stored resource" do
      number = ticket_number()
      # The store refuses a body past its size cap. A delivery is the one writer
      # that cannot be retried, so the refusal must leave a clean miss the reader
      # can act on rather than a truncated body it cannot detect.
      huge = String.duplicate("x", 300 * 1024)

      GithubWebhook.handle_delivery(
        "issue_comment",
        put_in(issue_comment_delivery(9209), ["comment", "body"], huge),
        repo: @repo
      )

      assert :miss = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_comment, @repo, 9209))
      # The issue rode along on the same delivery and is well within the cap.
      assert {:ok, _entry} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue, @repo, number))
    end

    test "a malformed or unsupported delivery deposits nothing and does not raise" do
      assert %{status: :dropped} =
               GithubWebhook.handle_delivery("issue_comment", %{"repository" => %{"full_name" => @repo}}, repo: @repo)

      assert %{status: :error} =
               GithubWebhook.handle_delivery(
                 "issue_comment",
                 %{"repository" => %{"full_name" => @repo}, "action" => "created"},
                 repo: @repo
               )

      assert %{status: :dropped} =
               GithubWebhook.handle_delivery("deployment_status", %{"repository" => %{"full_name" => @repo}}, repo: @repo)

      assert ResourceStore.size() == 0
    end
  end
end
