defmodule Aiur.GitHub.ReviewThreads.ResolutionPolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.ReviewThreads.ResolutionPolicy

  defp codeowners_repo!(content) do
    repo_root = Path.join(System.tmp_dir!(), "aiur-rp-test-#{System.unique_integer([:positive])}")
    path = Path.join(repo_root, ".github/CODEOWNERS")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    repo_root
  end

  defp thread_body(attrs \\ %{}) do
    %{
      "data" => %{
        "node" =>
          Map.merge(
            %{
              "id" => "PRRT_test",
              "isResolved" => false,
              "path" => "src/lib/foo.ex",
              "line" => 5,
              "comments" => %{
                "nodes" => [
                  %{
                    "id" => "PRRC_1",
                    "databaseId" => 1,
                    "body" => "please fix this",
                    "createdAt" => "2026-06-25T04:13:21Z",
                    "updatedAt" => "2026-06-25T04:13:21Z",
                    "url" => "https://github.test/discussion_r1",
                    "author" => %{"login" => "owner"}
                  },
                  %{
                    "id" => "PRRC_2",
                    "databaseId" => 2,
                    "body" => "Done, no further changes.",
                    "createdAt" => "2026-06-25T04:14:00Z",
                    "updatedAt" => "2026-06-25T04:14:00Z",
                    "url" => "https://github.test/discussion_r2",
                    "author" => %{"login" => "aiur-bot"}
                  }
                ]
              }
            },
            attrs
          )
      }
    }
  end

  describe "verify_review_thread_resolution_ready/5" do
    test "returns :ok when unresolved, bot terminal reply is latest, and reviewer is authoritative" do
      repo_root = codeowners_repo!("* @owner\n")

      assert {:ok, _verification} =
               ResolutionPolicy.verify_review_thread_resolution_ready(
                 thread_body(),
                 "PRRT_test",
                 "Done, no further changes.",
                 "aiur-bot",
                 repo_root: repo_root,
                 agent_logins: ["aiur-bot"]
               )

      File.rm_rf!(repo_root)
    end

    test "fails when the thread is already resolved" do
      repo_root = codeowners_repo!("* @owner\n")

      assert {:error, {:review_thread_resolution_precondition_failed, detail}} =
               ResolutionPolicy.verify_review_thread_resolution_ready(
                 thread_body(%{"isResolved" => true}),
                 "PRRT_test",
                 "Done, no further changes.",
                 "aiur-bot",
                 repo_root: repo_root,
                 agent_logins: ["aiur-bot"]
               )

      assert detail.reason == :already_resolved
      assert detail.review_thread_id == "PRRT_test"

      File.rm_rf!(repo_root)
    end

    test "fails when the latest comment is not from the bot" do
      repo_root = codeowners_repo!("* @owner\n")

      body_with_non_bot_latest =
        thread_body(%{
          "comments" => %{
            "nodes" => [
              %{
                "id" => "PRRC_1",
                "databaseId" => 1,
                "body" => "Done, no further changes.",
                "createdAt" => "2026-06-25T04:13:21Z",
                "updatedAt" => "2026-06-25T04:13:21Z",
                "url" => "https://github.test/discussion_r1",
                "author" => %{"login" => "aiur-bot"}
              },
              %{
                "id" => "PRRC_2",
                "databaseId" => 2,
                "body" => "Actually, please also change this.",
                "createdAt" => "2026-06-25T04:14:00Z",
                "updatedAt" => "2026-06-25T04:14:00Z",
                "url" => "https://github.test/discussion_r2",
                "author" => %{"login" => "owner"}
              }
            ]
          }
        })

      assert {:error, {:review_thread_resolution_precondition_failed, detail}} =
               ResolutionPolicy.verify_review_thread_resolution_ready(
                 body_with_non_bot_latest,
                 "PRRT_test",
                 "Done, no further changes.",
                 "aiur-bot",
                 repo_root: repo_root,
                 agent_logins: ["aiur-bot"]
               )

      assert detail.reason == :latest_comment_author_mismatch

      File.rm_rf!(repo_root)
    end

    test "reports ownership unavailable when a quota hold blocks team expansion" do
      repo_root = codeowners_repo!("* @acme/platform\n")
      request_fun = fn _request -> {:ok, %{status: 429, body: %{}}} end

      assert {:error, {:review_thread_resolution_ownership_unavailable, detail}} =
               ResolutionPolicy.verify_review_thread_resolution_ready(
                 thread_body(),
                 "PRRT_test",
                 "Done, no further changes.",
                 "aiur-bot",
                 repo_root: repo_root,
                 token: "token",
                 request_fun: request_fun,
                 agent_logins: ["aiur-bot"]
               )

      assert detail.review_thread_id == "PRRT_test"
      assert detail.path == "src/lib/foo.ex"
      assert detail.reason == :quota_hold

      File.rm_rf!(repo_root)
    end
  end

  describe "review_thread_authoritative_comment?/2" do
    test "returns true when the latest non-agent reviewer comment is CODEOWNERS-authoritative" do
      repo_root = codeowners_repo!("src/lib/foo.ex @owner\n")

      thread = %{
        "id" => "PRRT_test",
        "isResolved" => false,
        "path" => "src/lib/foo.ex",
        "comments" => %{
          "nodes" => [
            %{"author" => %{"login" => "owner"}, "body" => "please fix"},
            %{"author" => %{"login" => "aiur-bot"}, "body" => "fixed"}
          ]
        }
      }

      assert ResolutionPolicy.review_thread_authoritative_comment?(thread,
               repo_root: repo_root,
               agent_logins: ["aiur-bot"]
             )

      File.rm_rf!(repo_root)
    end

    test "returns false when there are no non-agent reviewer comments" do
      repo_root = codeowners_repo!("* @owner\n")

      thread = %{
        "id" => "PRRT_test",
        "isResolved" => false,
        "path" => "src/lib/foo.ex",
        "comments" => %{
          "nodes" => [
            %{"author" => %{"login" => "aiur-bot"}, "body" => "fixed"}
          ]
        }
      }

      refute ResolutionPolicy.review_thread_authoritative_comment?(thread,
               repo_root: repo_root,
               agent_logins: ["aiur-bot"]
             )

      File.rm_rf!(repo_root)
    end

    test "remains false when reviewer ownership is unavailable" do
      repo_root = codeowners_repo!("* @acme/platform\n")
      request_fun = fn _request -> {:ok, %{status: 429, body: %{}}} end
      thread = get_in(thread_body(), ["data", "node"])

      refute ResolutionPolicy.review_thread_authoritative_comment?(thread,
               repo_root: repo_root,
               token: "token",
               request_fun: request_fun,
               agent_logins: ["aiur-bot"]
             )

      File.rm_rf!(repo_root)
    end
  end
end
