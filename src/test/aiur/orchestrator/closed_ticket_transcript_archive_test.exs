defmodule Aiur.Orchestrator.ClosedTicketTranscriptArchiveTest do
  use ExUnit.Case, async: false

  alias Aiur.Orchestrator.ClosedTicketTranscriptArchive
  alias Aiur.RecentMerge

  test "archives only bounded agent transcripts under the run log root and applies count retention" do
    root = Aiur.TestSupport.tmp_root!("closed-ticket-transcript-archive")
    workspace = Path.join(root, "workspace")
    log_root = Path.join(root, "run-log")
    logs = Path.join(workspace, "logs")
    File.mkdir_p!(logs)
    File.write!(Path.join(logs, "agent.md"), "abcdef")
    File.write!(Path.join(logs, "agent.ndjson"), "0123456789")
    File.write!(Path.join(logs, "event-publications.ndjson"), "must not be copied")

    workspace_path = fn "42", nil -> {:ok, workspace} end
    archive_opts = [archive_root: Path.join(log_root, "closed-ticket-transcripts"), workspace_path_fun: workspace_path, max_file_bytes: 4, retention_limit: 1]

    try do
      assert :ok = ClosedTicketTranscriptArchive.archive("42", nil, archive_opts)
      first = Path.wildcard(Path.join([log_root, "closed-ticket-transcripts", "42", "*", "agent.md"]))
      assert [_] = first
      assert File.read!(hd(first)) == "[transcript truncated at 4 bytes]\ncdef"
      refute File.exists?(Path.join(Path.dirname(hd(first)), "event-publications.ndjson"))

      File.write!(Path.join(logs, "agent.md"), "second archive")
      assert :ok = ClosedTicketTranscriptArchive.archive("42", nil, archive_opts)
      retained = Path.wildcard(Path.join([log_root, "closed-ticket-transcripts", "42", "*", "agent.md"]))
      assert [_] = retained
      assert File.read!(hd(retained)) == "[transcript truncated at 4 bytes]\nhive"
    after
      Aiur.TestCleanup.rm_rf!(root)
    end
  end

  test "does not archive a ticket closed by a merged PR" do
    root = Aiur.TestSupport.tmp_root!("merged-ticket-archive")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(Path.join(workspace, "logs"))
    File.write!(Path.join([workspace, "logs", "agent.md"]), "should not be copied")
    now = DateTime.utc_now()

    merge = %RecentMerge{
      id: "merge-1",
      repository: "owner/repo",
      number: 1,
      url: "https://github.com/owner/repo/pull/1",
      merged_at: now,
      observation_source: :github_events,
      backfilled?: false,
      live_observed?: true,
      first_observed_at: now,
      last_observed_at: now,
      content_hash: "merge-hash",
      summary: "Closes #42"
    }

    try do
      archive_root = Path.join(root, "archive")

      assert :ok =
               ClosedTicketTranscriptArchive.archive("42", nil,
                 archive_root: archive_root,
                 workspace_path_fun: fn "42", nil -> {:ok, workspace} end,
                 recent_merges_fun: fn -> [merge] end
               )

      refute File.exists?(archive_root)
      refute ClosedTicketTranscriptArchive.merged_pr_close?("43", recent_merges_fun: fn -> [merge] end)
    after
      Aiur.TestCleanup.rm_rf!(root)
    end
  end

  test "skips remote transcript archiving so terminal cleanup can remove the workspace" do
    root = Aiur.TestSupport.tmp_root!("remote-ticket-transcript-archive")
    workspace = Path.join(root, "workspace")
    logs = Path.join(workspace, "logs")
    archive_root = Path.join(root, "archive")
    File.mkdir_p!(logs)
    File.write!(Path.join(logs, "agent.md"), "remote transcript")

    try do
      assert :ok =
               ClosedTicketTranscriptArchive.archive("42", "builder@remote",
                 archive_root: archive_root,
                 workspace_path_fun: fn "42", nil -> {:ok, workspace} end
               )

      refute File.exists?(archive_root)
    after
      Aiur.TestCleanup.rm_rf!(root)
    end
  end
end
