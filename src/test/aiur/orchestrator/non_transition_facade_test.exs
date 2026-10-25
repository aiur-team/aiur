defmodule Aiur.Orchestrator.NonTransitionFacadeTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.State

  test "submodules call non-transition owners directly" do
    names =
      ~w(note_github_connectivity_success note_github_connectivity_failure note_github_poll_interval connectivity_detail running_worker_host schedule_poll_cycle_start enqueue_event_digest_item cancel_ci_wait_rewake refresh_tracked_set clear_session_handle kill_repl_session close_active_chat_streams terminate_task reconcile_overrunning_agents reconcile_stalled_running_issues reconcile_runtime_health reconcile_pending_auto_resumes)

    pattern = Regex.compile!("\\b(?:Aiur\\.)?Orchestrator\\.(?:#{Enum.join(names, "|")})\\b")
    paths = Path.wildcard(Path.expand("../../../lib/aiur/orchestrator/**/*.ex", __DIR__))
    assert paths != []
    matches = Enum.filter(paths, fn path -> Regex.match?(pattern, File.read!(path)) end)
    assert matches == []
  end

  test "running_worker_host reads the running entry and preserves nil fallbacks" do
    state = %State{running: %{"hosted" => %{worker_host: "worker-1"}, "local" => %{pid: self()}}}
    assert State.WorkerHost.running_worker_host(state, "hosted") == "worker-1"
    assert State.WorkerHost.running_worker_host(state, "local") == nil
    assert State.WorkerHost.running_worker_host(state, "missing") == nil
    assert State.WorkerHost.running_worker_host(state, 123) == nil
    assert State.WorkerHost.running_worker_host(nil, "hosted") == nil
  end
end
