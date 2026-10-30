defmodule Aiur.RecentMergeLegacyReplayTest do
  use ExUnit.Case, async: false

  alias Aiur.{RecentMerge, RecentMergeStore}

  @now ~U[2026-07-12 18:00:00Z]

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur-recent-merge-legacy")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "replays a record written before commit messages were hashed", %{dir: dir} do
    merge = merge_for_number(4)
    legacy_record = record_before_commit_messages(merge)
    File.mkdir_p!(dir)
    path = Path.join(dir, "recent_merges.ndjson")
    File.write!(path, Jason.encode!(legacy_record) <> "\n")

    {:ok, replayed} =
      RecentMergeStore.start_link(
        name: nil,
        state_dir: dir,
        filesystem_sync_fun: fn -> :ok end
      )

    assert RecentMergeStore.health(replayed) == :writable
    assert [%RecentMerge{id: id, commit_messages: []}] = RecentMergeStore.list(replayed)
    assert id == merge.id
    assert :ok = RecentMergeStore.mark_ticket_reconciled(id, "ticket-4", replayed)
    assert RecentMergeStore.ticket_reconciled?(id, "ticket-4", replayed)
  end

  defp merge_for_number(number) do
    merged_at = DateTime.add(@now, number, :second)

    event = %{
      "id" => "evt-#{number}",
      "type" => "PullRequestEvent",
      "created_at" => DateTime.to_iso8601(merged_at),
      "actor" => %{"login" => "event-actor"},
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "action" => "closed",
        "pull_request" => %{
          "number" => number,
          "title" => "Legacy merge",
          "body" => "Historical record.",
          "html_url" => "https://github.com/owner/repo/pull/#{number}",
          "merged" => true,
          "merged_at" => DateTime.to_iso8601(merged_at),
          "merge_commit_sha" => "merge-#{number}",
          "head" => %{"ref" => "release/#{number}", "sha" => "head-#{number}"},
          "merged_by" => %{"login" => "merger"}
        }
      }
    }

    assert {:ok, merge} = RecentMerge.from_github_event(event, live?: false, now: merged_at)
    merge
  end

  defp record_before_commit_messages(%RecentMerge{} = merge) do
    old_hash =
      merge
      |> Map.from_struct()
      |> Map.drop([:commit_messages, :content_hash, :reconciled_ticket_ids, :issue_references])
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    merge
    |> RecentMerge.to_record()
    |> Map.delete("commit_messages")
    |> Map.put("content_hash", old_hash)
  end
end
