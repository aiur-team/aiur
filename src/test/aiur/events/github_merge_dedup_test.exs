defmodule Aiur.Events.GithubMergeDedupTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.{GithubFirehose, GithubWebhook.Triples}

  test "webhook and firehose publish a merged PR only once across source shapes" do
    pr = %{
      "number" => 7209,
      "merged" => true,
      "merged_at" => "2026-10-29T12:00:00Z",
      "merge_commit_sha" => "merge-sha-7209",
      "head" => %{"ref" => "aiur/7209", "sha" => "head-sha-7209"},
      "body" => "Closes #7209",
      "title" => "Fix duplicate merge event",
      "html_url" => "https://github.com/aiur-team/aiur/pull/7209"
    }

    webhook_payload = %{
      "repository" => %{"full_name" => "aiur-team/aiur"},
      "pull_request" => pr,
      "sender" => %{"login" => "human"}
    }

    assert {:publish, [{"ticket.7209.pr.merged", _payload, webhook_opts}]} =
             Triples.pull_request_triple(webhook_payload, pr, "closed", "aiur-team/aiur")

    firehose_event = %{
      "type" => "PullRequestEvent",
      "repo" => %{"name" => "aiur-team/aiur"},
      "actor" => %{"login" => "human"},
      "created_at" => "2026-10-29T12:00:00Z",
      "payload" => %{
        "action" => "merged",
        "pull_request" => Map.put(pr, "body", "Closes #7209")
      }
    }

    {"ticket.7209.pr.merged", _firehose_payload, firehose_opts} =
      GithubFirehose.PullRequest.translate(firehose_event, [])

    assert Keyword.fetch!(webhook_opts, :dedup_key) == Keyword.fetch!(firehose_opts, :dedup_key)

    assert Keyword.fetch!(webhook_opts, :dedup_key) ==
             {"aiur-team/aiur", "pr:merged:7209:7209", "merge-sha-7209"}
  end
end
