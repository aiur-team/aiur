defmodule Aiur.Events.GithubWebhook.DepositBodiesTest do
  @moduledoc """
  What a comment, review, pull request, check run or review-thread delivery deposits.

  Split out of `deposit_test.exs`, whose moduledoc states what these suites
  assert and why.
  """

  use Aiur.TestSupport.DepositCase

  alias Aiur.Events.GithubWebhook
  alias Aiur.GitHub.{PollSnapshots, ResourceStore}

  @repo "owner/repo"
  @human "its-everdred"

  describe "delivery types that deposit bodies" do
    test "issue_comment deposits the comment in the poller's shape" do
      GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9201), repo: @repo)

      assert {:ok, %{data: data, source: :webhook, version: "2026-06-24T12:00:00Z"}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:issue_comment, @repo, 9201))

      # The poller's projection, key for key: a consumer must not be able to
      # tell a delivered comment from a polled one.
      assert Map.keys(data) |> Enum.sort() ==
               ["body", "created_at", "html_url", "id", "updated_at", "user"]

      assert data["user"] == %{"login" => @human}
    end

    test "issue_comment deposits the issue and its label set" do
      number = ticket_number()
      GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9202), repo: @repo)

      assert {:ok, %{data: %{"number" => ^number}}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue, @repo, number))

      assert {:ok, %{data: [%{"name" => "agent:in-progress"}]}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:issue_labels, @repo, number))
    end

    test "pull_request_review_comment deposits the comment and the pull request" do
      assert :ok =
               PollSnapshots.put_review_threads(@repo, 77, [
                 %{"id" => "PRRT_old", "isResolved" => false, "comments" => %{"nodes" => []}}
               ])

      GithubWebhook.handle_delivery("pull_request_review_comment", review_comment_delivery(9203), repo: @repo)

      assert {:ok, %{data: %{"id" => 9203}, source: :webhook}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:pr_review_comment, @repo, 9203))

      assert {:ok, %{data: %{"number" => 77}}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:pull_request, @repo, 77))

      assert :miss = ResourceStore.fetch(PollSnapshots.review_threads_key(@repo, 77))
    end

    test "pull_request_review deposits the review with the poller's state casing" do
      GithubWebhook.handle_delivery("pull_request_review", review_delivery(9204), repo: @repo)

      assert {:ok, %{data: %{"state" => "CHANGES_REQUESTED"}, version: "2026-06-24T12:30:00Z"}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:pr_review, @repo, 9204))
    end

    test "pull_request_review_thread deposits its resolution generation" do
      ticket = ticket_id()
      fixture_value0 = "aiur/#{ticket}-a-ticket"

      payload = %{
        "action" => "unresolved",
        "repository" => %{"full_name" => @repo},
        "thread" => %{"id" => 88_001, "node_id" => "PRRT_kwDOabc", "comments" => 1},
        "updated_at" => "2026-08-21T12:00:00Z",
        "pull_request" => %{
          "number" => 77,
          "head" => %{"ref" => fixture_value0, "repo" => %{"full_name" => @repo}}
        }
      }

      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("pull_request_review_thread", payload,
                 repo: @repo,
                 reconcile_fun: fn _hint -> :ok end
               )

      assert {:ok,
              %{
                data: %{
                  "webhook_action" => "unresolved",
                  "generation" => "2026-08-21T12:00:00Z",
                  "latest_unresolved_generation" => "2026-08-21T12:00:00Z",
                  "updated_at" => "2026-08-21T12:00:00Z"
                }
              }} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:pr_review_thread, @repo, "PRRT_kwDOabc"))

      # The transition keeps its own clock in the marker data, never the entry's
      # version slot (which the comment pipe also writes on this same key).
      assert {:ok, %{version: nil}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:pr_review_thread, @repo, "PRRT_kwDOabc"))
    end

    test "a null review-thread timestamp uses the admitted delivery id as its generation" do
      ticket = ticket_id()
      fixture_value0 = "aiur/#{ticket}-a-ticket"

      payload = %{
        "action" => "unresolved",
        "repository" => %{"full_name" => @repo},
        "thread" => %{"id" => 88_002, "node_id" => "PRRT_kwDOnull", "comments" => 1},
        "updated_at" => nil,
        "pull_request" => %{
          "number" => 77,
          "head" => %{"ref" => fixture_value0, "repo" => %{"full_name" => @repo}}
        }
      }

      assert %{status: :reconciled, hint: %{generation: "delivery-fallback"}} =
               GithubWebhook.handle_delivery("pull_request_review_thread", payload,
                 repo: @repo,
                 delivery_id: "delivery-fallback",
                 reconcile_fun: fn _hint -> :ok end
               )

      assert {:ok, %{data: %{"generation" => "delivery-fallback"}, version: nil}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:pr_review_thread, @repo, "PRRT_kwDOnull"))

      assert %{status: :reconciled, hint: %{generation: "manual-redelivery"}} =
               GithubWebhook.handle_delivery("pull_request_review_thread", payload,
                 repo: @repo,
                 delivery_id: "manual-redelivery",
                 reconcile_fun: fn _hint -> :ok end
               )

      assert {:ok, %{data: %{"generation" => "delivery-fallback"}, version: nil}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:pr_review_thread, @repo, "PRRT_kwDOnull"))
    end

    test "pull_request deposits the pull request even when the event only reconciles" do
      # `synchronize` normalizes to a CI reconcile and publishes nothing, so a
      # deposit driven off the publish outcome would miss it entirely.
      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery(
                 "pull_request",
                 %{pull_request_delivery() | "action" => "synchronize"},
                 repo: @repo,
                 reconcile_fun: fn _hint -> :ok end
               )

      assert {:ok, %{data: %{"number" => 77}, source: :webhook}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:pull_request, @repo, 77))
    end

    # Acceptance #2126-1: `:pull_request` deposits and `:branch_pull_request`
    # reads resolve to the same key. Asserted by running the real delivery and
    # reading back the keys it wrote, with the ticket id derived from the PR's
    # own head branch — never from a number the test happened to choose.
    test ":pull_request deposits and :branch_pull_request reads resolve to the same key" do
      ticket = ticket_id()
      pr = pull_request()
      ticket_id = Aiur.TicketBranch.ticket_id(get_in(pr, ["head", "ref"]))
      assert ticket_id == ticket, "fixture's head branch must carry a parseable ticket id"

      deposit_keys = GithubWebhook.Deposit.deposit("pull_request", pull_request_delivery(), @repo)

      pr_key = ResourceStore.key_for_repo(:pull_request, @repo, pr["number"])
      branch_key = ResourceStore.key_for_repo(:branch_pull_request, @repo, ticket_id)

      assert pr_key in deposit_keys
      assert branch_key in deposit_keys

      # The key the human-review gate builds to read it (`context.issue_number`
      # is the ticket number, `human_review_gate.ex:106`).
      read_key = ResourceStore.key_for_repo(:branch_pull_request, @repo, ticket_id)
      assert branch_key == read_key
    end

    # Acceptance #2126-1 second half, in the other direction: a pull request
    # delivery deposits the open PR under the ticket whose branch it belongs to,
    # and that body is the same object the `:pull_request` key holds.
    test "a pull_request delivery also deposits the open pull request under its ticket" do
      ticket = ticket_id()
      number = ticket_number()
      fixture_value0 = "aiur/#{ticket}-a-ticket"
      GithubWebhook.handle_delivery("pull_request", pull_request_delivery(), repo: @repo)

      assert {:ok, %{data: %{"number" => 77, "head" => %{"ref" => ^fixture_value0}}}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:branch_pull_request, @repo, number))
    end

    # A head branch that is not an Aiur ticket branch has no ticket key the gate
    # could read, so depositing one would be exactly the write-to-nowhere this
    # table exists to catch.
    test "a PR on a non-ticket branch is deposited only under its own number" do
      number = ticket_number()
      non_ticket = %{pull_request_delivery() | "pull_request" => %{pull_request() | "head" => %{"ref" => "main"}}}

      keys = GithubWebhook.Deposit.deposit("pull_request", non_ticket, @repo)

      assert ResourceStore.key_for_repo(:pull_request, @repo, 77) in keys
      refute ResourceStore.key_for_repo(:branch_pull_request, @repo, number) in keys
      assert ResourceStore.fetch(ResourceStore.key_for_repo(:branch_pull_request, @repo, number)) == :miss
    end

    test "a check_run delivery advances an existing complete CI-context snapshot" do
      ticket = ticket_id()
      number = ticket_number()
      fixture_value0 = "aiur/#{ticket}-a-ticket"

      assert :ok =
               PollSnapshots.put_ci_contexts(
                 @repo,
                 number,
                 "deadbeef",
                 [
                   %{
                     "id" => 5501,
                     "name" => "test",
                     "status" => "queued",
                     "conclusion" => nil,
                     "started_at" => "2026-06-24T12:00:00Z",
                     "completed_at" => nil,
                     "output" => %{}
                   }
                 ],
                 %{"state" => "pending", "statuses" => []}
               )

      delivery = %{
        "action" => "completed",
        "check_run" => %{
          "id" => 5501,
          "name" => "test",
          "status" => "completed",
          "conclusion" => "success",
          "head_sha" => "deadbeef",
          "app" => %{"id" => 15_368},
          "started_at" => "2026-06-24T12:00:00Z",
          "completed_at" => "2026-06-24T12:01:00Z",
          "output" => %{},
          "pull_requests" => [%{"head" => %{"ref" => fixture_value0}}]
        }
      }

      assert [PollSnapshots.ci_contexts_key(@repo, number)] == GithubWebhook.Deposit.deposit("check_run", delivery, @repo)

      assert {:ok, %{"check_runs" => [%{"id" => 5501, "status" => "completed", "app" => %{"id" => 15_368}}]}} =
               PollSnapshots.ci_contexts(@repo, number)
    end

    test "a resolved review-thread delivery advances an existing complete thread collection" do
      ticket = ticket_id()
      number = ticket_number()
      fixture_value0 = "aiur/#{ticket}-a-ticket"

      assert :ok =
               PollSnapshots.put_review_threads(@repo, 77, [
                 %{
                   "id" => "PRRT_5502",
                   "isResolved" => false,
                   "updatedAt" => "2026-06-24T12:00:00Z",
                   "path" => "src/lib/example.ex",
                   "line" => 7,
                   "comments" => %{"nodes" => [%{"databaseId" => 1, "body" => "fix"}]}
                 }
               ])

      delivery = %{
        "action" => "resolved",
        "pull_request" => %{"number" => 77, "head" => %{"ref" => fixture_value0}},
        "thread" => %{
          "node_id" => "PRRT_5502",
          "is_resolved" => true,
          "updated_at" => "2026-06-24T12:01:00Z",
          "path" => "src/lib/example.ex",
          "line" => 7
        }
      }

      # A thread delivery also deposits the full PR it carries — the half that
      # feeds `DeliveredPullRequest` (#2326) — alongside the snapshot merge and
      # the transition marker (#2279) that records the resolve/unresolve
      # generation.
      assert [
               ResourceStore.key_for_repo(:pull_request, @repo, 77),
               ResourceStore.key_for_repo(:branch_pull_request, @repo, number),
               PollSnapshots.review_threads_key(@repo, 77),
               ResourceStore.key_for_repo(:pr_review_thread, @repo, "PRRT_5502")
             ] ==
               GithubWebhook.Deposit.deposit("pull_request_review_thread", delivery, @repo)

      assert {:ok,
              [
                %{
                  "id" => "PRRT_5502",
                  "isResolved" => true,
                  "comments" => %{"nodes" => [%{"databaseId" => 1}]}
                }
              ]} = PollSnapshots.review_threads(@repo, 77)
    end

    test "a resolved delivery for an unknown thread does not bless an incomplete collection" do
      assert :ok = PollSnapshots.put_review_threads(@repo, 77, [])

      delivery = %{
        "action" => "resolved",
        "pull_request" => %{"number" => 77},
        "thread" => %{"node_id" => "PRRT_unknown", "updated_at" => "2026-06-24T12:01:00Z"}
      }

      # The unknown thread is not merged into the empty snapshot, but the PR the
      # delivery carries is still deposited (#2326) and the transition marker is
      # still recorded (#2279).
      assert [
               ResourceStore.key_for_repo(:pull_request, @repo, 77),
               PollSnapshots.review_threads_key(@repo, 77),
               ResourceStore.key_for_repo(:pr_review_thread, @repo, "PRRT_unknown")
             ] ==
               GithubWebhook.Deposit.deposit("pull_request_review_thread", delivery, @repo)

      assert :miss = PollSnapshots.review_threads(@repo, 77)
    end

    test "an unresolved delivery drops a snapshot that says the thread is resolved" do
      assert :ok =
               PollSnapshots.put_review_threads(@repo, 77, [
                 %{"id" => "PRRT_5504", "isResolved" => false, "updatedAt" => "2026-06-24T12:00:00Z"}
               ])

      resolved = %{
        "action" => "resolved",
        "pull_request" => %{"number" => 77},
        "thread" => %{"node_id" => "PRRT_5504", "is_resolved" => true, "updated_at" => "2026-06-24T12:01:00Z"}
      }

      assert [
               ResourceStore.key_for_repo(:pull_request, @repo, 77),
               PollSnapshots.review_threads_key(@repo, 77),
               ResourceStore.key_for_repo(:pr_review_thread, @repo, "PRRT_5504")
             ] ==
               GithubWebhook.Deposit.deposit("pull_request_review_thread", resolved, @repo)

      assert {:ok, [%{"isResolved" => true}]} = PollSnapshots.review_threads(@repo, 77)

      # The reviewer un-resolves it seconds later. Serving the resolved snapshot
      # for the rest of the window filters the thread out of the unaddressed set
      # and drops the re-raised objection silently.
      unresolved = %{
        "action" => "unresolved",
        "pull_request" => %{"number" => 77},
        "thread" => %{"node_id" => "PRRT_5504", "is_resolved" => false, "updated_at" => "2026-06-24T12:02:00Z"}
      }

      # An invalidation writes no body, so it reports no thread key — but the
      # delivery's PR half is still deposited (#2326) and the transition marker
      # still advances (#2279).
      assert [
               ResourceStore.key_for_repo(:pull_request, @repo, 77),
               ResourceStore.key_for_repo(:pr_review_thread, @repo, "PRRT_5504")
             ] ==
               GithubWebhook.Deposit.deposit("pull_request_review_thread", unresolved, @repo)

      assert :miss = PollSnapshots.review_threads(@repo, 77)
    end

    test "a delivered thread collection survives a store restart and is still delivery-fresh" do
      ticket = ticket_id()
      number = ticket_number()
      fixture_value0 = "aiur/#{ticket}-a-ticket"
      path = Aiur.TestSupport.tmp_root!("aiur-resource-store") <> ".json"
      on_exit(fn -> File.rm_rf!(path) end)

      # Run against a real checkpoint file before depositing: an in-memory store
      # would let the restart pass without ever writing the round trip.
      :ok = restart_store!(path)

      assert :ok =
               PollSnapshots.put_review_threads(@repo, 77, [
                 %{
                   "id" => "PRRT_5503",
                   "isResolved" => false,
                   "updatedAt" => "2026-06-24T12:00:00Z",
                   "path" => "src/lib/example.ex",
                   "line" => 7,
                   "comments" => %{"nodes" => [%{"databaseId" => 1, "body" => "fix"}]}
                 }
               ])

      delivery = %{
        "action" => "resolved",
        "pull_request" => %{"number" => 77, "head" => %{"ref" => fixture_value0}},
        "thread" => %{
          "node_id" => "PRRT_5503",
          "is_resolved" => true,
          "updated_at" => "2026-06-24T12:01:00Z",
          "path" => "src/lib/example.ex",
          "line" => 7
        }
      }

      # A thread delivery also deposits the full PR it carries — including its
      # `:branch_pull_request` sibling when the head branch is a ticket — which
      # is what keeps `DeliveredPullRequest` from falling into the per-PR
      # `review_threads_unaddressed` fallback (#2326), plus the transition
      # marker (#2279).
      assert [
               ResourceStore.key_for_repo(:pull_request, @repo, 77),
               ResourceStore.key_for_repo(:branch_pull_request, @repo, number),
               PollSnapshots.review_threads_key(@repo, 77),
               ResourceStore.key_for_repo(:pr_review_thread, @repo, "PRRT_5503")
             ] ==
               GithubWebhook.Deposit.deposit("pull_request_review_thread", delivery, @repo)

      :ok = ResourceStore.flush()
      :ok = restart_store!(path)

      # The collection came back complete, still carrying the delivery's advance
      # and still attributed to the webhook — so a poller that consults it after
      # a daemon restart still stands down rather than paying to re-ask.
      assert {:ok, [%{"id" => "PRRT_5503", "isResolved" => true}]} = PollSnapshots.review_threads(@repo, 77)
    end
  end
end
