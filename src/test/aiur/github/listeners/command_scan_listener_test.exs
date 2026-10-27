defmodule Aiur.GitHub.Listeners.CommandScanListenerTest do
  use Aiur.TestSupport
  alias Aiur.Events.GithubKeys
  alias Aiur.GitHub.Listeners
  alias Aiur.GitHub.Listeners.CommandScan
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Orchestrator.{CommandPolling, State, TrackerTasks}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", pr_watch_enabled: true)
    %{listener: start_supervised!({CommandScan, []})}
  end

  test "since and both validators advance in the listener across two scans", %{listener: listener} do
    warm(listener)
    ResourceStore.reset()
    assert :ok = Listeners.scan_commands(probe(listener, self()))
    assert_received {:review, "2026-06-25T01:59:59Z", "review-etag"}
    assert_received {:issue, "2026-06-25T01:59:59Z", "issue-etag"}
  end

  test "reset clears since and etags before the next scan", %{listener: listener} do
    warm(listener)
    # Remove durable bodies to observe only the in-memory validators after reset.
    ResourceStore.reset()
    assert :ok = GenServer.call(listener, :reset)
    assert :ok = Listeners.scan_commands(probe(listener, self()))
    cutoff = GithubKeys.boot_cutoff_iso8601(boot_time: 1_782_352_800)
    assert_received {:review, ^cutoff, nil}
    assert_received {:issue, ^cutoff, nil}
  end

  test "reset cancels an in-flight scan and rejects its late result", %{listener: listener} do
    warm(listener)
    opts = blocked_opts(listener, self())
    caller = Task.async(fn -> Listeners.scan_commands(opts) end)
    receive_barrier({:started, worker})
    assert :ok = GenServer.call(listener, :reset)
    assert Task.await(caller) == {:error, :command_scan_reset}
    refute Process.alive?(worker)
    assert :sys.get_state(listener).cursor == %CommandScan.Scan{}
  end

  test "tracker timeout cancels the listener worker and retains its cursor", %{listener: listener} do
    warm(listener)
    pending = CommandPolling.scan(%State{snapshot_key: self()}, blocked_opts(listener, self()))
    receive_barrier({:started, worker})
    ref = Process.monitor(worker)
    [task_ref] = Map.keys(pending.tracker_tasks)
    log = ExUnit.CaptureLog.capture_log(fn -> assert TrackerTasks.timeout(pending, task_ref).tracker_tasks == %{} end)
    receive_barrier({:DOWN, ^ref, :process, ^worker, :killed})
    assert log =~ "PR command scan task failed"
    assert :ok = Listeners.scan_commands(probe(listener, self()))
    assert_received {:review, "2026-06-25T01:59:59Z", "review-etag"}
  end

  test "a crashed scan preserves the cursor and permits the next scan", %{listener: listener} do
    warm(listener)

    assert {:error, {:tracker_task_exit, :controlled_crash}} =
             Listeners.scan_commands(server: listener, command_scan_review_comment_fetcher: fn _ -> exit(:controlled_crash) end)

    assert :ok = Listeners.scan_commands(probe(listener, self()))
    assert_received {:review, "2026-06-25T01:59:59Z", "review-etag"}
  end

  defp warm(listener) do
    comment = %{"id" => 981, "body" => "ordinary comment", "updated_at" => "2026-06-25T02:00:00Z", "pull_request_url" => "https://api.github.com/repos/owner/repo/pulls/77"}

    assert :ok =
             Listeners.scan_commands(
               server: listener,
               boot_time: 1_782_352_800,
               command_scan_review_comment_fetcher: fn _ -> {:ok, [comment], "review-etag"} end,
               command_scan_issue_comment_fetcher: fn _ -> {:ok, [], "issue-etag"} end
             )
  end

  defp probe(listener, owner) do
    [
      server: listener,
      boot_time: 1_782_352_800,
      command_scan_review_comment_fetcher: fn opts ->
        send(owner, {:review, opts[:since], opts[:etag]})
        {:ok, []}
      end,
      command_scan_issue_comment_fetcher: fn opts ->
        send(owner, {:issue, opts[:since], opts[:etag]})
        {:ok, []}
      end
    ]
  end

  defp blocked_opts(listener, owner) do
    [
      server: listener,
      command_scan_review_comment_fetcher: fn _ ->
        send(owner, {:started, self()})
        receive do: (:release -> {:ok, []})
      end,
      command_scan_issue_comment_fetcher: fn _ -> {:ok, []} end
    ]
  end
end
