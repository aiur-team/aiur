defmodule Aiur.GitHub.Client.ReviewCommentsTest do
  use Aiur.TestSupport

  import Aiur.GitHub.ClientTestSupport

  alias Aiur.GitHub.Client

  setup do
    setup_client()
  end

  describe "fetch_classified_pr_review_comments/2" do
    test "labels CODEOWNER review comments authoritative" do
      repo_root = codeowners_repo!("* @owner")

      request_fun = fn %{method: :get, url: url} ->
        cond do
          url =~ "/repos/owner/repo/pulls/7/files" ->
            {:ok, %{status: 200, body: [%{"filename" => "lib/app.ex"}]}}

          url =~ "/repos/owner/repo/pulls/7/comments" ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{"user" => %{"login" => "owner"}, "body" => "Fix this"},
                 %{"user" => %{"login" => "guest"}, "body" => "Maybe fix this"}
               ]
             }}
        end
      end

      assert {:ok, [owner_comment, guest_comment]} =
               Client.fetch_classified_pr_review_comments("7",
                 request_fun: request_fun,
                 repo_root: repo_root
               )

      assert owner_comment.authoritative
      assert owner_comment.authority_reason =~ "CODEOWNER via @owner"
      refute guest_comment.authoritative
      assert guest_comment.authority_reason == "Author is not a CODEOWNER for the relevant paths."

      File.rm_rf!(repo_root)
    end

    test "fails closed on comments when CODEOWNERS is missing" do
      repo_root = Aiur.TestSupport.tmp_root!("aiur-github-client-test")

      File.mkdir_p!(repo_root)

      request_fun = fn %{method: :get, url: url} ->
        cond do
          url =~ "/repos/owner/repo/pulls/8/files" ->
            {:ok, %{status: 200, body: [%{"filename" => "lib/app.ex"}]}}

          url =~ "/repos/owner/repo/pulls/8/comments" ->
            {:ok, %{status: 200, body: [%{"user" => %{"login" => "guest"}, "body" => "Fix this"}]}}
        end
      end

      assert {:ok, [comment]} =
               Client.fetch_classified_pr_review_comments(8,
                 request_fun: request_fun,
                 repo_root: repo_root
               )

      # Prove we really are on the degraded path and not failing for some other
      # reason: there is no CODEOWNERS file under this repo root.
      refute comment.codeowners.codeowners_present

      # SECURITY INVARIANT — this used to be a "compatibility fallback" that made
      # EVERY commenter authoritative whenever CODEOWNERS was missing. On a
      # public repo with issues enabled that meant a drive-by comment from any
      # outsider was handed to the agent as a trusted instruction. Degraded-mode
      # trust now has exactly one owner, `Aiur.GitHub.CodeOwners`, which trusts
      # only `bot_account` + `trusted_accounts` (falling back to the repo owner).
      # `guest` is none of those, so the answer is no.
      #
      # This harness configures no trust source, so the assertion is the
      # fail-closed default rather than the positive case. The positive case —
      # an explicitly configured trusted account IS authoritative in degraded
      # mode — is covered in `test/aiur/codeowners_test.exs`, which can inject a
      # `:trust_server`; this client path resolves the trust server itself and
      # has no seam to inject one.
      refute comment.authoritative

      assert comment.authority_reason ==
               "No CODEOWNERS rules found; only explicitly configured trusted accounts are authoritative."

      File.rm_rf!(repo_root)
    end

    test "abstains when a team-backed CODEOWNERS lookup is quota-held" do
      repo_root = codeowners_repo!("* @acme/platform")

      request_fun = fn %{method: :get, url: url} ->
        cond do
          url =~ "/repos/owner/repo/pulls/9/files" ->
            {:ok, %{status: 200, body: [%{"filename" => "lib/app.ex"}]}}

          url =~ "/repos/owner/repo/pulls/9/comments" ->
            {:ok, %{status: 200, body: [%{"user" => %{"login" => "owner"}, "body" => "Fix this"}]}}

          url =~ "/orgs/acme/teams/platform/members" ->
            {:ok, %{status: 429, body: %{}}}
        end
      end

      assert {:error, :quota_hold} =
               Client.fetch_classified_pr_review_comments(9,
                 request_fun: request_fun,
                 repo_root: repo_root
               )

      File.rm_rf!(repo_root)
    end
  end

  describe "fetch_unaddressed_pr_review_thread_comments/2" do
    test "returns latest trusted comments from unresolved threads only" do
      repo_root = codeowners_repo!("src/owned.ts @owner\n")

      request_fun = fn
        %{method: :post, url: "https://api.github.com/graphql", body: body} ->
          assert body["query"] =~ "reviewThreads"
          assert body["variables"]["owner"] == "owner"
          assert body["variables"]["repo"] == "repo"
          assert body["variables"]["number"] == 61

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "repository" => %{
                   "pullRequest" => %{
                     "reviewThreads" => %{
                       "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                       "nodes" => [
                         %{
                           "id" => "PRRT_first",
                           "isResolved" => false,
                           "path" => "src/owned.ts",
                           "line" => 10,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(101, "owner", "please fix this")
                             ]
                           }
                         },
                         %{
                           "id" => "PRRT_resolved",
                           "isResolved" => true,
                           "path" => "src/owned.ts",
                           "line" => 11,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(102, "owner", "resolved already")
                             ]
                           }
                         },
                         %{
                           "id" => "PRRT_answered",
                           "isResolved" => false,
                           "path" => "src/owned.ts",
                           "line" => 12,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(103, "owner", "agent answered this"),
                               review_thread_comment(104, "aiur-bot", "addressed")
                             ]
                           }
                         },
                         %{
                           "id" => "PRRT_untrusted",
                           "isResolved" => false,
                           "path" => "src/owned.ts",
                           "line" => 13,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(105, "guest", "not trusted")
                             ]
                           }
                         },
                         %{
                           "id" => "PRRT_followup",
                           "isResolved" => false,
                           "path" => "src/owned.ts",
                           "line" => 14,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(106, "owner", "old request"),
                               review_thread_comment(107, "owner", "reviewer follow-up")
                             ]
                           }
                         },
                         %{
                           "id" => "PRRT_no_code_changes",
                           "isResolved" => false,
                           "path" => "src/owned.ts",
                           "line" => 15,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(
                                 108,
                                 "owner",
                                 "wake test, no code changes needed"
                               )
                             ]
                           }
                         }
                       ]
                     }
                   }
                 }
               }
             }
           }}
      end

      assert {:ok, comments} =
               Client.fetch_unaddressed_pr_review_thread_comments(61,
                 request_fun: request_fun,
                 repo_root: repo_root,
                 agent_logins: ["aiur-bot"]
               )

      assert Enum.map(comments, & &1["id"]) == [101, 104, 107, 108]

      assert Enum.map(comments, & &1["review_thread_id"]) == [
               "PRRT_first",
               "PRRT_answered",
               "PRRT_followup",
               "PRRT_no_code_changes"
             ]

      assert Enum.map(comments, & &1["body"]) == [
               "please fix this",
               "addressed",
               "reviewer follow-up",
               "wake test, no code changes needed"
             ]

      assert Enum.all?(comments, & &1.authoritative)
      assert Enum.find(comments, &(&1["review_thread_id"] == "PRRT_answered"))["review_thread_resolution_required"]

      File.rm_rf!(repo_root)
    end
  end
end
