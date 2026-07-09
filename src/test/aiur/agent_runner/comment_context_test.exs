defmodule Aiur.AgentRunner.CommentContextTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.CommentContext
  alias Aiur.Issue

  describe "events/2" do
    test "returns [] for a non-Issue argument" do
      assert CommentContext.events(:not_an_issue, %{}) == []
      assert CommentContext.events(nil, %{}) == []
      assert CommentContext.events(%{}, %{}) == []
    end

    test "returns [] for an Issue without a binary identifier" do
      issue = %Issue{identifier: nil, id: "gid-1"}

      assert CommentContext.events(issue, %{}) == []
    end

    test "returns [] when issue_comments fetcher errors" do
      issue = %Issue{identifier: "CC-01", id: "gid-cc01"}

      fetchers = %{
        issue_comments: fn _id -> {:error, :not_found} end,
        open_pr: fn _id -> {:ok, nil} end,
        pr_review_comments: fn _id -> {:ok, []} end,
        unaddressed_pr_review_thread_comments: fn _pr -> {:ok, []} end
      }

      assert CommentContext.events(issue, fetchers) == []
    end

    test "excludes workpad comments and returns post-cutoff comments" do
      issue = %Issue{identifier: "CC-02", id: "gid-cc02"}

      workpad = %{
        "id" => 1,
        "body" => "## Agent Workpad\nsome notes",
        "updated_at" => "2025-01-01T00:00:00Z",
        :authoritative => false
      }

      after_cutoff = %{
        "id" => 2,
        "body" => "a follow-up comment",
        "updated_at" => "2025-01-02T00:00:00Z",
        :authoritative => true
      }

      fetchers = %{
        issue_comments: fn _id -> {:ok, [workpad, after_cutoff]} end,
        open_pr: fn _id -> {:ok, nil} end,
        pr_review_comments: fn _id -> {:ok, []} end,
        unaddressed_pr_review_thread_comments: fn _pr -> {:ok, []} end
      }

      events = CommentContext.events(issue, fetchers)

      assert length(events) == 1
      [event] = events
      assert event.topic == "ticket.CC-02.issue.commented"
      summary = get_in(event, [:comment, "body"]) || get_in(event, [:comment, :body]) || ""
      assert summary =~ "a follow-up comment"
    end

    test "dedupes by (topic, comment_id) so the same comment on the same topic appears only once" do
      issue = %Issue{identifier: "CC-03", id: "gid-cc03"}

      shared_id = 99
      comment = %{"id" => shared_id, "body" => "shared", "updated_at" => "2025-06-01T00:00:00Z", :authoritative => true}

      fetchers = %{
        issue_comments: fn _id -> {:ok, [comment]} end,
        open_pr: fn _id -> {:ok, %{"number" => 7}} end,
        pr_review_comments: fn _pr -> {:ok, []} end,
        unaddressed_pr_review_thread_comments: fn _pr -> {:ok, []} end
      }

      events = CommentContext.events(issue, fetchers)

      keys = Enum.map(events, fn ev -> {ev.topic, ev.id} end)
      assert keys == Enum.uniq(keys)
    end
  end
end
