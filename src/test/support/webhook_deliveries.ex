defmodule Aiur.TestSupport.WebhookDeliveries do
  @moduledoc false
  @repo "owner/repo"

  def graphql_request(number) do
    %{
      method: :post,
      url: "https://api.github.com/graphql",
      token: "t",
      body: %{
        "query" => "query Q($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { t0: issueOrPullRequest(number: #{number}) { ... on Issue { title } } } }",
        "variables" => %{"owner" => "owner", "repo" => "repo"}
      },
      caller: "issue_relationships"
    }
  end

  def issue_comment_delivery(ticket, repository \\ %{"full_name" => @repo}, comment \\ nil) do
    %{
      "action" => "created",
      "repository" => repository,
      "issue" => %{"number" => String.to_integer(ticket), "title" => "a ticket"},
      "comment" =>
        comment ||
          %{
            "id" => 1_001,
            "body" => "please rework this",
            "created_at" => "2026-06-24T12:00:00Z",
            "updated_at" => "2026-06-24T12:00:00Z",
            "user" => %{"login" => "its-everdred"}
          },
      "sender" => %{"login" => "its-everdred"}
    }
  end

  def review_delivery(ticket, state \\ "CHANGES_REQUESTED", body \\ "needs work") do
    %{
      "action" => "submitted",
      "repository" => %{"full_name" => @repo},
      "sender" => %{"login" => "its-everdred"},
      "review" => %{
        "id" => 55_001,
        "state" => state,
        "body" => body,
        "submitted_at" => "2026-06-24T12:00:00Z",
        "user" => %{"login" => "its-everdred"}
      },
      "pull_request" => %{"number" => 901, "head" => %{"ref" => "aiur/#{ticket}-slug", "sha" => "deadbeef"}}
    }
  end

  def review_thread_delivery(ticket, action) do
    %{
      "action" => action,
      "repository" => %{"full_name" => @repo},
      "thread" => %{
        "id" => 88_001,
        "node_id" => "PRRT_kwDOabc",
        "comments" => 1
      },
      "updated_at" => "2026-08-21T12:00:00Z",
      "pull_request" => %{
        "number" => 901,
        "head" => %{"ref" => "aiur/#{ticket}-slug", "sha" => "deadbeef", "repo" => %{"full_name" => @repo}}
      }
    }
  end
end
