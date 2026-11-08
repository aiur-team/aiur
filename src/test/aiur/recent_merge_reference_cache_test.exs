defmodule Aiur.RecentMergeReferenceCacheTest do
  use ExUnit.Case, async: false

  alias Aiur.RecentMerge
  alias Aiur.RecentMerge.ClosingReferences

  test "normalized and replayed records never preprocess text on repeated identifier reads" do
    merge = merge("Closes #12\nRefs #13\n> Closes #99\n```\nRefs #98\n```", ["Fixes #14\nRefs #15"])
    record = RecentMerge.to_record(merge)
    refute Map.has_key?(record, "issue_references")
    assert {:ok, replayed} = RecentMerge.decode_record(record)

    assert trace_quotable_calls(fn ->
             for candidate <- [merge, replayed], _ <- 1..5 do
               assert RecentMerge.closing_issue_identifiers(candidate) == ["12", "14"]
               assert RecentMerge.linked_issue_identifiers(candidate) == ["13", "12", "15", "14"]
             end
           end) == 0
  end

  test "combined parsing preprocesses each body once" do
    assert trace_quotable_calls(fn ->
             assert ClosingReferences.parse("Refs #13\nCloses #12\n`Fixes #99`", "owner/repo") ==
                      {["12"], ["13", "12"]}
           end) == 1
  end

  test "enrichment refreshes references and direct struct edits cannot return stale identifiers" do
    original = merge("Closes #12", ["Refs #13"])
    incoming = merge("Closes #21", ["Refs #22"])
    assert {:accepted, enriched} = RecentMerge.enrich(original, incoming)
    assert RecentMerge.closing_issue_identifiers(enriched) == ["21"]
    assert RecentMerge.linked_issue_identifiers(enriched) == ["21", "22"]

    assert trace_quotable_calls(fn ->
             assert RecentMerge.closing_issue_identifiers(enriched) == ["21"]
             assert RecentMerge.linked_issue_identifiers(enriched) == ["21", "22"]
           end) == 0

    edited = %{original | summary: "Closes #31", repository: "other/repo", commit_messages: ["Refs #32"]}
    assert RecentMerge.closing_issue_identifiers(edited) == ["31"]
    assert RecentMerge.linked_issue_identifiers(edited) == ["31", "32"]
  end

  defp trace_quotable_calls(fun) do
    Code.ensure_loaded!(ClosingReferences)
    task = Task.async(fn -> receive do: (:go -> fun.()) end)
    mfa = {ClosingReferences, :quotable_text, 1}
    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(task.pid, true, [:call])

    try do
      send(task.pid, :go)
      Task.await(task)
      ref = :erlang.trace_delivered(task.pid)
      count_calls(task.pid, ref, 0)
    after
      :erlang.trace_pattern(mfa, false, [:local])
    end
  end

  defp count_calls(pid, ref, count) do
    receive do
      {:trace, ^pid, :call, {ClosingReferences, :quotable_text, [_]}} -> count_calls(pid, ref, count + 1)
      {:trace_delivered, ^pid, ^ref} -> count
    end
  end

  defp merge(body, messages) do
    now = DateTime.utc_now()

    event = %{
      "type" => "PullRequestEvent",
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "action" => "closed",
        "pull_request" => %{
          "number" => 42,
          "merged" => true,
          "merged_at" => DateTime.to_iso8601(now),
          "body" => body,
          "commit_messages" => messages
        }
      }
    }

    assert {:ok, merge} = RecentMerge.from_github_event(event, now: now)
    merge
  end
end
