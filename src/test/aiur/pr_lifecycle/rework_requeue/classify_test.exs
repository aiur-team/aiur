defmodule Aiur.PRLifecycle.ReworkRequeue.ClassifyTest do
  use ExUnit.Case, async: true

  alias Aiur.PRLifecycle.ReworkRequeue

  # The blocking review judged head `a`; the PR then moved to head `b`.
  @review_commit "sha-a"
  @head_sha "sha-b"
  @base_sha "base-sha"

  defp pr(overrides) do
    Map.merge(
      %{
        "number" => 2346,
        "title" => "PR #2346",
        "state" => "open",
        "draft" => false,
        "base" => %{"sha" => @base_sha, "ref" => "main"},
        "head" => %{"sha" => @head_sha, "ref" => "aiur/2337-pr-turnaround-is-bimodal"}
      },
      overrides
    )
  end

  defp review(overrides) do
    Map.merge(
      %{
        "id" => 1,
        "state" => "CHANGES_REQUESTED",
        "commit_id" => @review_commit,
        "submitted_at" => "2026-08-22T20:00:00Z",
        "user" => %{"login" => "its-everdred"}
      },
      overrides
    )
  end

  defp default_diff_files, do: [{"lib/foo.ex", "blob-sha-1"}]

  describe "latest_blocking_review/1" do
    test "picks the latest CHANGES_REQUESTED review" do
      reviews = [
        review(%{"id" => 1, "submitted_at" => "2026-08-22T18:00:00Z"}),
        review(%{"id" => 2, "submitted_at" => "2026-08-22T20:00:00Z"}),
        %{"id" => 3, "state" => "APPROVED", "submitted_at" => "2026-08-22T21:00:00Z"}
      ]

      assert ReworkRequeue.latest_blocking_review(reviews)["id"] == 2
    end

    test "returns nil when no review blocks" do
      assert ReworkRequeue.latest_blocking_review([%{"state" => "APPROVED"}]) == nil
      assert ReworkRequeue.latest_blocking_review([]) == nil
    end
  end

  describe "classify/3" do
    test ":not_addressed when the head is still the commit the review judged" do
      pr = pr(%{"head" => %{"sha" => @review_commit}})

      assert ReworkRequeue.classify(pr, review(%{}), diff_fetcher: fn _ -> {:ok, default_diff_files()} end) ==
               :not_addressed
    end

    test ":addressed when the own contribution diff changed since the review" do
      # Review-time own diff has one file; the head own diff has a second —
      # genuine rework, whatever the timestamps say.
      diff_fetcher = fn
        {@base_sha, @review_commit} -> {:ok, [{"lib/foo.ex", "blob-sha-1"}]}
        {@base_sha, @head_sha} -> {:ok, [{"lib/foo.ex", "blob-sha-1"}, {"lib/bar.ex", "blob-sha-2"}]}
      end

      assert ReworkRequeue.classify(pr(%{}), review(%{}), diff_fetcher: diff_fetcher) == :addressed
    end

    test ":addressed when the same file's content changed since the review" do
      diff_fetcher = fn
        {@base_sha, @review_commit} -> {:ok, [{"lib/foo.ex", "blob-sha-1"}]}
        {@base_sha, @head_sha} -> {:ok, [{"lib/foo.ex", "blob-sha-2"}]}
      end

      assert ReworkRequeue.classify(pr(%{}), review(%{}), diff_fetcher: diff_fetcher) == :addressed
    end

    test ":merge_only when commits landed but the own contribution diff is identical" do
      # The head moved (a merge of main) but the own contribution is unchanged
      # — a merge-only push must NOT be read as rework.
      diff_fetcher = fn
        {@base_sha, @review_commit} -> {:ok, default_diff_files()}
        {@base_sha, @head_sha} -> {:ok, default_diff_files()}
      end

      assert ReworkRequeue.classify(pr(%{}), review(%{}), diff_fetcher: diff_fetcher) == :merge_only
    end

    test ":unknown when the own-diff cannot be fetched" do
      diff_fetcher = fn _ -> {:error, :timeout} end

      assert ReworkRequeue.classify(pr(%{}), review(%{}), diff_fetcher: diff_fetcher) == :unknown
    end

    test ":unknown when a required identity field is absent" do
      assert ReworkRequeue.classify(pr(%{"head" => %{"sha" => nil}}), review(%{}), diff_fetcher: fn _ -> {:ok, []} end) ==
               :unknown

      assert ReworkRequeue.classify(pr(%{}), review(%{"commit_id" => nil}), diff_fetcher: fn _ -> {:ok, []} end) ==
               :unknown
    end
  end
end
