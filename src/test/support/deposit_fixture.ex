defmodule Aiur.TestSupport.DepositFixture do
  @moduledoc false
  # Keep delivery builders together so their resource identifiers stay consistent.
  import Aiur.TestSupport.EventTicket
  @repo "owner/repo"
  @human "its-everdred"

  def issue_comment_delivery(id, body \\ "review this", author \\ @human) do
    %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "issue" => issue(),
      "comment" => comment(id, body, "2026-06-24T12:00:00Z", author),
      "sender" => %{"login" => author}
    }
  end

  def issues_delivery(action) do
    %{
      "action" => action,
      "repository" => %{"full_name" => @repo},
      "issue" => issue(),
      "sender" => %{"login" => @human}
    }
  end

  def review_comment_delivery(id) do
    %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "pull_request" => pull_request(),
      "comment" => comment(id, "inline note", "2026-06-24T12:00:00Z", @human),
      "sender" => %{"login" => @human}
    }
  end

  def review_delivery(id) do
    %{
      "action" => "submitted",
      "repository" => %{"full_name" => @repo},
      "pull_request" => pull_request(),
      "review" => %{
        "id" => id,
        "state" => "changes_requested",
        "body" => "needs work",
        "submitted_at" => "2026-06-24T12:30:00Z",
        "user" => %{"login" => @human}
      },
      "sender" => %{"login" => @human}
    }
  end

  def pull_request_delivery do
    %{
      "action" => "opened",
      "repository" => %{"full_name" => @repo},
      "pull_request" => pull_request(),
      "sender" => %{"login" => @human}
    }
  end

  def sub_issue_added_delivery do
    number = ticket_number()

    %{
      "action" => "sub_issue_added",
      "repository" => %{"full_name" => @repo},
      "parent_issue_id" => "IS_parent",
      "sub_issue_id" => "IS_sub_1",
      "parent_issue_number" => number,
      "parent_issue_repo" => @repo,
      "sub_issue_number" => 21,
      "sub_issue_repo" => @repo,
      "sub_issue" => %{
        "node_id" => "IS_sub_1",
        "number" => 21,
        "title" => "a sub-issue",
        "state" => "open",
        "updated_at" => "2026-06-24T13:00:00Z"
      },
      "parent_issue" => %{
        "node_id" => "IS_parent",
        "number" => number,
        "title" => "a build order root",
        "state" => "open",
        "updated_at" => "2026-06-24T12:00:00Z"
      },
      "sender" => %{"login" => @human}
    }
  end

  # GitHub's `pull_request_review_thread` delivery (resolved/unresolved) carries
  # the thread and a full pull request; only the PR half is deposited.
  def pull_request_review_thread_delivery do
    %{
      "action" => "resolved",
      "repository" => %{"full_name" => @repo},
      "thread" => %{"id" => "PRRT_kwDOTHREAD1"},
      "pull_request" => pull_request(),
      "sender" => %{"login" => @human}
    }
  end

  def sub_issue_removed_delivery do
    number = ticket_number()

    %{
      "action" => "sub_issue_removed",
      "repository" => %{"full_name" => @repo},
      "parent_issue_id" => "IS_parent",
      "sub_issue_id" => "IS_sub_1",
      "parent_issue_number" => number,
      "parent_issue_repo" => @repo,
      "sub_issue_number" => 21,
      "sub_issue_repo" => @repo,
      "sender" => %{"login" => @human}
    }
  end

  def dependency_created_delivery do
    number = ticket_number()

    %{
      "action" => "blocked_by_added",
      "repository" => %{"full_name" => @repo},
      "blocked_issue_number" => number,
      "blocked_issue_repo" => @repo,
      "blocking_issue_number" => 99,
      "blocking_issue_repo" => @repo,
      "dependency" => %{
        "dependency_id" => "DI_1",
        "dependant_id" => "IS_parent",
        "dependency" => %{
          "node_id" => "IS_99",
          "number" => 99,
          "title" => "a blocker",
          "state" => "open",
          "updated_at" => "2026-06-24T13:30:00Z"
        },
        "dependant" => %{
          "node_id" => "IS_parent",
          "number" => number,
          "title" => "a build order root",
          "state" => "open",
          "updated_at" => "2026-06-24T12:00:00Z"
        }
      },
      "sender" => %{"login" => @human}
    }
  end

  # GitHub's `sub_issues` delivery carries the full sub-issue and parent issue,
  # plus the top-level edge facts (`parent_issue_number`/`sub_issue_number`)
  # the #2313 edge deposit keys the `:sub_issue` entry by.
  def sub_issues_delivery do
    ticket = ticket_id()
    number = ticket_number()
    fixture_value0 = "DI_parent_#{ticket}"

    %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "sub_issue" => %{issue() | "number" => 41, "updated_at" => "2026-06-24T10:30:00Z"},
      "parent_issue" => issue(),
      "parent_issue_id" => fixture_value0,
      "parent_issue_number" => number,
      "parent_issue_repo" => @repo,
      "sub_issue_id" => "DI_sub_41",
      "sub_issue_number" => 41,
      "sub_issue_repo" => @repo,
      "sender" => %{"login" => @human}
    }
  end

  def dependency_removed_delivery do
    number = ticket_number()

    %{
      "action" => "blocked_by_removed",
      "repository" => %{"full_name" => @repo},
      "blocked_issue_number" => number,
      "blocked_issue_repo" => @repo,
      "blocking_issue_number" => 99,
      "blocking_issue_repo" => @repo,
      "dependency" => %{"dependency_id" => "DI_1"},
      "sender" => %{"login" => @human}
    }
  end

  # GitHub's `issue_dependencies` delivery carries the issue whose dependency
  # edge changed, plus the blocker edge, and the action tells the direction. The
  # top-level `blocked_issue_number`/`blocking_issue_number` edge facts are what
  # the #2313 edge deposit keys the `:issue_dependency` entry by.
  def issue_dependencies_delivery do
    ticket = ticket_id()
    number = ticket_number()
    fixture_value0 = "DI_blocked_#{ticket}"

    %{
      "action" => "blocked_by_added",
      "repository" => %{"full_name" => @repo},
      "issue" => issue(),
      "blocked_by_issue" => %{"id" => 80_001, "number" => 80, "updated_at" => "2026-06-24T10:00:00Z"},
      "blocked_issue_id" => fixture_value0,
      "blocked_issue_number" => number,
      "blocked_issue_repo" => @repo,
      "blocking_issue_id" => "DI_blocker_80",
      "blocking_issue_number" => 80,
      "blocking_issue_repo" => @repo,
      "sender" => %{"login" => @human}
    }
  end

  def issue do
    number = ticket_number()

    %{
      "number" => number,
      "title" => "a ticket",
      "body" => "the ask",
      "state" => "open",
      "updated_at" => "2026-06-24T11:00:00Z",
      "labels" => [%{"name" => "agent:in-progress"}]
    }
  end

  def pull_request do
    ticket = ticket_id()
    fixture_value0 = "aiur/#{ticket}-a-ticket"

    %{
      "number" => 77,
      "state" => "open",
      "updated_at" => "2026-06-24T11:30:00Z",
      "head" => %{"ref" => fixture_value0, "sha" => "abc123"}
    }
  end

  def comment(id, body, updated_at \\ "2026-06-24T12:00:00Z", author \\ @human) do
    %{
      "id" => id,
      "body" => body,
      "created_at" => updated_at,
      "updated_at" => updated_at,
      "html_url" => "https://example.test/comments/#{id}",
      "user" => %{"login" => author}
    }
  end
end
