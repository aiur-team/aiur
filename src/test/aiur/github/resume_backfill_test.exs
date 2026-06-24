defmodule Aiur.GitHub.ResumeBackfillTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.ResumeBackfill
  alias Aiur.Workflow

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn -> restore_env("GITHUB_TOKEN", prev_token) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    :ok
  end

  # Mirrors the #35/#49 case from issue #485: a review comment is posted
  # to the ticket's PR while the agent is offline. On resume the backfill
  # must surface that comment body on the topic the resumed agent
  # subscribes to.
  describe "backfill_pr_comments/2" do
    test "delivers PR comments posted while the agent was offline" do
      parent = self()

      request_fun = fn %{method: :get, url: url} ->
        decoded = URI.decode(url)

        cond do
          decoded =~ "/pulls?head=owner:aiur/35&state=open" ->
            {:ok, %{status: 200, body: [%{"number" => 49}]}}

          decoded =~ "/repos/owner/repo/issues/49/comments" ->
            {:ok,
             %{
               status: 200,
               body: [%{"id" => 4_783_049_689, "user" => %{"login" => "its-everdred"}, "body" => "Codex review result"}]
             }}

          decoded =~ "/repos/owner/repo/pulls/49/files" ->
            {:ok, %{status: 200, body: [%{"filename" => "lib/app.ex"}]}}

          decoded =~ "/repos/owner/repo/pulls/49/comments" ->
            {:ok,
             %{
               status: 200,
               body: [%{"id" => 555, "user" => %{"login" => "its-everdred"}, "body" => "Inline nit"}]
             }}

          true ->
            flunk("unexpected request: #{decoded}")
        end
      end

      publish_fun = fn topic, payload, opts ->
        send(parent, {:published, topic, payload, opts})
        {:ok, 1, 1}
      end

      assert :ok =
               ResumeBackfill.backfill_pr_comments("35",
                 repo: "owner/repo",
                 request_fun: request_fun,
                 publish_fun: publish_fun
               )

      assert_received {:published, "ticket.35.issue.commented", conv_payload, conv_opts}
      assert get_in(conv_payload, [:comment, "body"]) == "Codex review result"
      assert conv_opts[:bypass_contamination]
      assert conv_opts[:issue_number] == "35"
      assert conv_opts[:dedup_key] == {"owner/repo", "issue_comment:49", "4783049689"}

      assert_received {:published, "ticket.35.pr.review_comment", review_payload, review_opts}
      assert get_in(review_payload, [:comment, "body"]) == "Inline nit"
      assert review_opts[:dedup_key] == {"owner/repo", "pr_review_comment:49", "555"}
    end

    test "no-ops when the branch has no open PR" do
      request_fun = fn %{method: :get} -> {:ok, %{status: 200, body: []}} end
      publish_fun = fn _topic, _payload, _opts -> flunk("should not publish without a PR") end

      assert :ok =
               ResumeBackfill.backfill_pr_comments("35",
                 repo: "owner/repo",
                 request_fun: request_fun,
                 publish_fun: publish_fun
               )
    end

    test "swallows GitHub failures without publishing" do
      request_fun = fn %{method: :get} -> {:ok, %{status: 500, body: %{}}} end
      publish_fun = fn _topic, _payload, _opts -> flunk("should not publish on error") end

      assert :ok =
               ResumeBackfill.backfill_pr_comments("35",
                 repo: "owner/repo",
                 request_fun: request_fun,
                 publish_fun: publish_fun
               )
    end
  end
end
