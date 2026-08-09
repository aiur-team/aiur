defmodule Aiur.Events.GithubKeysTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.GithubKeys

  describe "ref_to_topic/1" do
    test "routes legacy and readable ticket branches" do
      assert GithubKeys.ref_to_topic("refs/heads/aiur/647") ==
               {:ticket, "647", "ticket.647.branch.push"}

      assert GithubKeys.ref_to_topic("refs/heads/aiur/647-add-new-test-cases") ==
               {:ticket, "647", "ticket.647.branch.push"}
    end

    test "rejects malformed or unrelated aiur branch variants" do
      assert GithubKeys.ref_to_topic("refs/heads/aiur/647x") == nil
      assert GithubKeys.ref_to_topic("refs/heads/aiur/647-") == nil
      assert GithubKeys.ref_to_topic("refs/heads/aiur/647--pr") == nil
      assert GithubKeys.ref_to_topic("refs/heads/aiur/647/sub") == nil
      assert GithubKeys.ref_to_topic("refs/heads/aiur/abc") == nil
    end

    test "routes single-segment system branches" do
      assert GithubKeys.ref_to_topic("refs/heads/main") == {:system, "system.main.branch.push"}
    end

    test "rejects unsupported refs" do
      assert GithubKeys.ref_to_topic("refs/tags/v1") == nil
      assert GithubKeys.ref_to_topic(nil) == nil
    end
  end

  describe "dedup keys" do
    test "builds PR lifecycle dedup keys" do
      assert GithubKeys.pr_dedup_key("owner/repo", 12, "opened", "headsha") ==
               {"owner/repo", "pr:opened:12", "headsha"}

      assert GithubKeys.pr_dedup_key("owner/repo", "12", "opened", "headsha") == nil
    end

    test "builds comment dedup keys" do
      assert GithubKeys.comment_dedup_key("owner/repo", "issue_comment", 42, 1001) ==
               {"owner/repo", "issue_comment:42", "1001"}

      assert GithubKeys.comment_dedup_key("owner/repo", "issue_comment", "42", 1001) == nil
    end

    test "builds review thread dedup keys from stable node ids" do
      assert GithubKeys.review_thread_dedup_key("owner/repo", 61, "PRRT_kwDORkWEz86MGwBK") ==
               {"owner/repo", "pr_review_thread:61", "PRRT_kwDORkWEz86MGwBK"}

      assert GithubKeys.review_thread_dedup_key("owner/repo", 61, "") == nil

      assert GithubKeys.review_thread_dedup_key("owner/repo", "61", "PRRT_kwDORkWEz86MGwBK") ==
               nil
    end

    test "builds PR review submission dedup keys from review ids" do
      assert GithubKeys.pr_review_dedup_key("owner/repo", 61, 9_999_001) ==
               {"owner/repo", "pr_review:61", "9999001"}

      assert GithubKeys.pr_review_dedup_key("owner/repo", 61, 9_999_002) !=
               GithubKeys.pr_review_dedup_key("owner/repo", 61, 9_999_001)

      assert GithubKeys.pr_review_dedup_key("owner/repo", 62, 9_999_001) !=
               GithubKeys.pr_review_dedup_key("owner/repo", 61, 9_999_001)

      assert GithubKeys.pr_review_dedup_key("owner/repo", "61", 9_999_001) == nil
      assert GithubKeys.pr_review_dedup_key("owner/repo", 61, "9999001") == nil
      assert GithubKeys.pr_review_dedup_key(nil, 61, 9_999_001) == nil
    end
  end

  describe "boot cutoff" do
    test "uses injected boot time with a sixty second back-window" do
      assert GithubKeys.boot_cutoff_epoch_seconds(boot_time: 1_782_302_400) == 1_782_302_340
      assert GithubKeys.boot_cutoff_iso8601(boot_time: 1_782_302_400) == "2026-06-24T11:59:00Z"
    end

    test "detects events older than the boot back-window" do
      old_event = %{"created_at" => "2026-06-24T11:58:59Z"}
      cutoff_event = %{"created_at" => "2026-06-24T11:59:00Z"}
      new_event = %{"created_at" => "2026-06-24T11:59:01Z"}

      assert GithubKeys.pre_boot_event?(old_event, boot_time: 1_782_302_400)
      refute GithubKeys.pre_boot_event?(cutoff_event, boot_time: 1_782_302_400)
      refute GithubKeys.pre_boot_event?(new_event, boot_time: 1_782_302_400)
      refute GithubKeys.pre_boot_event?(%{"created_at" => "not-a-date"}, boot_time: 1_782_302_400)
    end
  end
end
