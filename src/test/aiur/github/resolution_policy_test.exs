defmodule Aiur.GitHub.ReviewThreads.ResolutionPolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.ReviewThreads.ResolutionPolicy

  defp codeowners_repo!(content) do
    repo_root = Path.join(System.tmp_dir!(), "aiur-rp-test-#{System.pid()}-#{System.unique_integer([:positive])}")
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

  # SPLIT IDENTITY — every test above uses one login for both Aiur roles, which
  # is the shape that hid the original conflation. These use two different
  # logins, because that is the only configuration where classifying the wrong
  # one still shows up as a failure.
  #
  # This path never reaches `BotIdentity.codeowners_classification_opts/1`, so
  # the union has to happen in `agent_classification_opts/2`. Without it the
  # daemon's own App-bot comment is taken for the reviewer's comment and checked
  # for CODEOWNERS authority it never had.
  describe "agent_classification_opts/2 under a split identity" do
    test "carries both Aiur logins into :agent_logins" do
      opts = ResolutionPolicy.agent_classification_opts("aiur-daemon[bot]", bot_account: "its-applekid")

      assert Keyword.get(opts, :agent_logins) == ["aiur-daemon[bot]", "its-applekid"]
    end

    test "keeps caller-supplied agent logins" do
      opts =
        ResolutionPolicy.agent_classification_opts("aiur-daemon[bot]",
          bot_account: "its-applekid",
          agent_logins: ["extra-agent"]
        )

      assert Keyword.get(opts, :agent_logins) == ["aiur-daemon[bot]", "its-applekid", "extra-agent"]
    end

    # Single-identity installs are the shipped default: one entry, not a pair.
    test "collapses to one login when both roles share an account" do
      opts = ResolutionPolicy.agent_classification_opts("aiur-bot", bot_account: "aiur-bot")

      assert Keyword.get(opts, :agent_logins) == ["aiur-bot"]
    end

    # The daemon's own comment must not be mistaken for the reviewer's: with
    # only the agent login classified, `review_thread_authority/2` would walk
    # back to the App-bot comment, call it the reviewer's, and refuse to resolve
    # a thread the real owner had already answered.
    test "a daemon App-bot comment is not treated as the reviewer's comment" do
      repo_root = codeowners_repo!("* @owner\n")

      thread = %{
        "id" => "PRRT_test",
        "isResolved" => false,
        "path" => "src/lib/foo.ex",
        "comments" => %{
          "nodes" => [
            %{"author" => %{"login" => "owner"}, "body" => "please fix"},
            %{"author" => %{"login" => "its-applekid"}, "body" => "fixed"},
            %{"author" => %{"login" => "aiur-daemon[bot]"}, "body" => "Done, no further changes."}
          ]
        }
      }

      opts =
        ResolutionPolicy.agent_classification_opts("aiur-daemon[bot]",
          repo_root: repo_root,
          bot_account: "its-applekid"
        )

      assert ResolutionPolicy.review_thread_authoritative_comment?(thread, opts)

      File.rm_rf!(repo_root)
    end
  end
end
