defmodule Aiur.Webhooks.EventKeyTest do
  use ExUnit.Case, async: true

  alias Aiur.Webhooks.EventKey

  defp repo, do: %{"full_name" => "owner/repo"}

  defp comment_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "action" => "created",
        "repository" => repo(),
        "issue" => %{"number" => 42},
        "comment" => %{"id" => 9001, "updated_at" => "2026-08-09T10:00:00Z"}
      },
      overrides
    )
  end

  test "two deliveries carrying the same comment event derive the same key" do
    assert EventKey.derive("issue_comment", comment_payload()) ==
             EventKey.derive("issue_comment", comment_payload())
  end

  test "an edit to the same comment derives a different key" do
    edited =
      comment_payload(%{
        "action" => "edited",
        "comment" => %{"id" => 9001, "updated_at" => "2026-08-09T10:05:00Z"}
      })

    refute EventKey.derive("issue_comment", comment_payload()) == EventKey.derive("issue_comment", edited)
  end

  test "the same comment id in another repository derives a different key" do
    other = comment_payload(%{"repository" => %{"full_name" => "owner/other"}})

    refute EventKey.derive("issue_comment", comment_payload()) == EventKey.derive("issue_comment", other)
  end

  test "a labeled and an unlabeled event at the same second derive different keys" do
    issue = %{"number" => 7, "updated_at" => "2026-08-09T10:00:00Z", "labels" => []}

    labeled = %{
      "action" => "labeled",
      "repository" => repo(),
      "issue" => issue,
      "label" => %{"name" => "agent:todo"}
    }

    unlabeled = %{labeled | "action" => "unlabeled", "label" => %{"name" => "agent:in-progress"}}

    refute EventKey.derive("issues", labeled) == EventKey.derive("issues", unlabeled)
  end

  test "pull request keys separate action and head sha" do
    base = %{
      "action" => "synchronize",
      "repository" => repo(),
      "pull_request" => %{
        "number" => 3,
        "updated_at" => "2026-08-09T10:00:00Z",
        "head" => %{"sha" => "aaa"}
      }
    }

    moved = put_in(base, ["pull_request", "head", "sha"], "bbb")

    assert EventKey.derive("pull_request", base) == EventKey.derive("pull_request", base)
    refute EventKey.derive("pull_request", base) == EventKey.derive("pull_request", moved)
  end

  test "review thread keys identify the pull request, thread, and action" do
    payload = %{
      "action" => "resolved",
      "repository" => repo(),
      "pull_request" => %{"number" => 42},
      "thread" => %{"node_id" => "PRRT_abc"}
    }

    assert EventKey.derive("pull_request_review_thread", payload) ==
             "pull_request_review_thread:owner/repo:42:PRRT_abc:resolved"

    refute EventKey.derive("pull_request_review_thread", payload) ==
             EventKey.derive("pull_request_review_thread", %{payload | "action" => "unresolved"})
  end

  test "push keys use the ref and resulting sha" do
    payload = %{"repository" => repo(), "ref" => "refs/heads/main", "after" => "abc123"}

    assert EventKey.derive("push", payload) == "push:owner/repo:refs/heads/main:abc123"
  end

  test "unknown events and incomplete payloads derive no key" do
    assert EventKey.derive("membership", %{"repository" => repo()}) == nil
    assert EventKey.derive("issue_comment", %{"repository" => repo()}) == nil
    assert EventKey.derive("issue_comment", comment_payload(%{"repository" => %{}})) == nil
    assert EventKey.derive(nil, comment_payload()) == nil
    assert EventKey.derive("issue_comment", "not a map") == nil
  end
end
