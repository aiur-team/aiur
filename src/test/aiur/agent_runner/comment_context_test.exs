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

  describe "events/2 PR comments and review threads" do
    test "collects issue comments, PR review comments, and unaddressed review threads" do
      issue = %Issue{identifier: "CC-10", id: "gid-cc10"}

      issue_comment = %{"id" => 100, "body" => "issue level", "updated_at" => "2025-03-01T00:00:00Z", :authoritative => true}
      pr_review = %{"id" => 200, "body" => "review nit", "updated_at" => "2025-03-02T00:00:00Z", :authoritative => true}
      thread = %{"id" => 300, "body" => "unaddressed thread", :authoritative => true}

      fetchers = %{
        issue_comments: fn
          "CC-10" -> {:ok, [issue_comment]}
          7 -> {:ok, []}
        end,
        open_pr: fn _ -> {:ok, %{"number" => 7}} end,
        pr_review_comments: fn 7 -> {:ok, [pr_review]} end,
        unaddressed_pr_review_thread_comments: fn 7 -> {:ok, [thread]} end
      }

      events = CommentContext.events(issue, fetchers)
      topics = Enum.map(events, & &1.topic)
      ids = Enum.map(events, & &1.id)

      assert "ticket.CC-10.issue.commented" in topics
      assert "ticket.CC-10.pr.review_comment" in topics
      # Unaddressed review threads are collected regardless of the workpad cutoff.
      assert 100 in ids
      assert 200 in ids
      assert 300 in ids
    end

    test "logs and continues with only issue events when the open-PR lookup errors" do
      issue = %Issue{identifier: "CC-11", id: "gid-cc11"}
      comment = %{"id" => 1, "body" => "hello", "updated_at" => "2025-01-01T00:00:00Z", :authoritative => true}

      fetchers = %{
        issue_comments: fn _ -> {:ok, [comment]} end,
        open_pr: fn _ -> {:error, :api_down} end,
        pr_review_comments: fn _ -> {:ok, []} end,
        unaddressed_pr_review_thread_comments: fn _ -> {:ok, []} end
      }

      events = CommentContext.events(issue, fetchers)

      assert Enum.map(events, & &1.id) == [1]
    end

    test "yields no PR events when the open PR has no number" do
      issue = %Issue{identifier: "CC-12", id: "gid-cc12"}

      fetchers = %{
        issue_comments: fn _ -> {:ok, []} end,
        open_pr: fn _ -> {:ok, %{"title" => "no number"}} end,
        pr_review_comments: fn _ -> {:ok, [%{"id" => 9, "body" => "x", :authoritative => true}]} end,
        unaddressed_pr_review_thread_comments: fn _ -> {:ok, []} end
      }

      assert CommentContext.events(issue, fetchers) == []
    end

    test "accepts a string PR number and still collects review comments" do
      issue = %Issue{identifier: "CC-13", id: "gid-cc13"}
      review = %{"id" => 55, "body" => "string-pr review", "updated_at" => "2025-04-01T00:00:00Z", :authoritative => true}

      fetchers = %{
        issue_comments: fn _ -> {:ok, []} end,
        open_pr: fn _ -> {:ok, %{"number" => "42"}} end,
        pr_review_comments: fn "42" -> {:ok, [review]} end,
        unaddressed_pr_review_thread_comments: fn "42" -> {:ok, []} end
      }

      events = CommentContext.events(issue, fetchers)
      assert 55 in Enum.map(events, & &1.id)
    end

    test "skips unaddressed-thread collection when the fetcher key is absent" do
      issue = %Issue{identifier: "CC-14", id: "gid-cc14"}

      fetchers = %{
        issue_comments: fn _ -> {:ok, []} end,
        open_pr: fn _ -> {:ok, %{"number" => 7}} end,
        pr_review_comments: fn _ -> {:ok, []} end
      }

      assert CommentContext.events(issue, fetchers) == []
    end

    test "continues when a PR review-comment fetch errors" do
      issue = %Issue{identifier: "CC-15", id: "gid-cc15"}
      comment = %{"id" => 1, "body" => "issue", "updated_at" => "2025-01-01T00:00:00Z", :authoritative => true}

      fetchers = %{
        issue_comments: fn
          "CC-15" -> {:ok, [comment]}
          7 -> {:ok, []}
        end,
        open_pr: fn _ -> {:ok, %{"number" => 7}} end,
        pr_review_comments: fn _ -> {:error, :boom} end,
        unaddressed_pr_review_thread_comments: fn _ -> {:error, :boom} end
      }

      events = CommentContext.events(issue, fetchers)
      assert Enum.map(events, & &1.id) == [1]
    end
  end

  describe "events/2 comment normalisation" do
    test "excludes durable agent-authored comments while retaining trusted shared-login comments" do
      issue = %Issue{identifier: "CC-ORIGIN", id: "gid-cc-origin"}

      agent_comment = %{
        "id" => 71,
        "body" => "agent review-resolution reply",
        "updated_at" => "2025-07-01T00:00:00Z",
        "user" => %{"login" => "shared-login"},
        :authoritative => true
      }

      human_comment = %{
        "id" => 72,
        "body" => "human follow-up",
        "updated_at" => "2025-07-02T00:00:00Z",
        "user" => %{"login" => "shared-login"},
        :authoritative => true
      }

      fetchers = %{
        issue_comments: fn _ -> {:ok, [agent_comment, human_comment]} end,
        open_pr: fn _ -> {:ok, nil} end,
        pr_review_comments: fn _ -> {:ok, []} end,
        unaddressed_pr_review_thread_comments: fn _ -> {:ok, []} end,
        comment_origin_resolver: fn _identifier, comment ->
          if comment["id"] == 71, do: "agent", else: "external"
        end
      }

      assert [%{id: 72, author_trusted?: true, comment_origin: "external"}] =
               CommentContext.events(issue, fetchers)
    end

    test "generates an integer id for a non-integer comment id and extracts the author login" do
      issue = %Issue{identifier: "CC-20", id: "gid-cc20"}

      comment = %{
        "id" => "not-an-integer",
        "body" => "hi",
        "createdAt" => "2025-01-01T00:00:00Z",
        "user" => %{"login" => "octocat"},
        :authoritative => true
      }

      fetchers = %{
        issue_comments: fn _ -> {:ok, [comment]} end,
        open_pr: fn _ -> {:ok, nil} end,
        pr_review_comments: fn _ -> {:ok, []} end,
        unaddressed_pr_review_thread_comments: fn _ -> {:ok, []} end
      }

      [event] = CommentContext.events(issue, fetchers)

      assert is_integer(event.id)
      assert event.author == "octocat"
      assert event.summary =~ "hi"
    end

    test "uses the latest workpad timestamp as the cutoff across multiple workpads" do
      issue = %Issue{identifier: "CC-21", id: "gid-cc21"}

      early_workpad = %{"id" => 1, "body" => "## Agent Workpad\nv1", "updated_at" => "2025-01-01T00:00:00Z", :authoritative => false}
      late_workpad = %{"id" => 2, "body" => "## Agent Workpad\nv2", "updated_at" => "2025-06-01T00:00:00Z", :authoritative => false}
      before_cut = %{"id" => 3, "body" => "stale", "updated_at" => "2025-03-01T00:00:00Z", :authoritative => true}
      after_cut = %{"id" => 4, "body" => "fresh", "updated_at" => "2025-07-01T00:00:00Z", :authoritative => true}

      fetchers = %{
        issue_comments: fn _ -> {:ok, [early_workpad, late_workpad, before_cut, after_cut]} end,
        open_pr: fn _ -> {:ok, nil} end,
        pr_review_comments: fn _ -> {:ok, []} end,
        unaddressed_pr_review_thread_comments: fn _ -> {:ok, []} end
      }

      ids = issue |> CommentContext.events(fetchers) |> Enum.map(& &1.id)

      # Only the comment after the latest (June) workpad survives the cutoff.
      assert ids == [4]
    end
  end
end
