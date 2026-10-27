defmodule Aiur.AlertsTransitionsTest do
  use Aiur.TestSupport

  alias Aiur.{AlertLedger, Alerts, Orchestrator}
  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.IssueSync

  describe "resolution alerts are edge-triggered" do
    setup do
      log_root = Aiur.TestSupport.tmp_root!("aiur-alert-resolution")
      original_log_file = Application.get_env(:aiur, :log_file)
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(log_root) end)
      Aiur.TestSupport.put_runtime_state_dir!(log_root)

      on_exit(fn ->
        if original_log_file do
          Application.put_env(:aiur, :log_file, original_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end
      end)

      {:ok, log_root: log_root}
    end

    test "one firing-to-cleared transition records exactly one resolution" do
      condition = "system.github.quota.core.exhausted"
      resolution = condition <> ".resolved"

      assert :ok = Alerts.emit_system(condition, message: "alert", reason: "0 of 5000 requests remaining", needs_attention: true)

      Enum.each(1..4, fn _cycle ->
        assert :ok =
                 Alerts.emit_system(resolution, message: "alert", reason: "GitHub core exhausted quota alert cleared; 4905 of 5000 requests remain", needs_attention: false)
      end)

      assert ledger_topic_count(resolution) == 1
    end

    test "a condition that stays clear records nothing further" do
      resolution = "system.github.quota.core.low.resolved"

      assert :ok = Alerts.emit_system("system.github.quota.core.low", message: "alert", reason: "low", needs_attention: true)
      assert :ok = Alerts.emit_system(resolution, message: "alert", reason: "cleared", needs_attention: false)

      before = ledger_records()
      Enum.each(1..10, fn _poll -> assert :ok = Alerts.emit_system(resolution, message: "alert", reason: "cleared", needs_attention: false) end)

      assert ledger_records() == before
    end

    test "a re-fire earns a second, distinct resolution" do
      condition = "system.dispatch.prewarm_blocked"
      resolution = condition <> ".resolved"

      assert :ok = Alerts.emit_system(condition, message: "alert", reason: "prewarm is building", needs_attention: true)
      assert :ok = Alerts.emit_system(resolution, message: "alert", reason: "prewarm is ready", needs_attention: false)
      assert :ok = Alerts.emit_system(resolution, message: "alert", reason: "prewarm is ready", needs_attention: false)
      assert ledger_topic_count(resolution) == 1

      assert :ok = Alerts.emit_system(condition, message: "alert", reason: "prewarm is fetching", needs_attention: true)
      assert :ok = Alerts.emit_system(resolution, message: "alert", reason: "prewarm is ready again", needs_attention: false)

      assert ledger_topic_count(resolution) == 2
      assert Enum.any?(ledger_records(), &(&1["topic"] == resolution and &1["reason"] == "prewarm is ready again"))
    end

    test "a suppressed resolution is not published to the topic exchange" do
      condition = "system.github.quota.graphql.exhausted"
      resolution = condition <> ".resolved"

      assert :ok = Alerts.emit_system(condition, message: "alert", reason: "graphql exhausted", needs_attention: true)
      assert :ok = Alerts.emit_system(resolution, message: "alert", reason: "graphql cleared", needs_attention: false)

      :ok = Exchange.subscribe(resolution)
      assert :ok = Alerts.emit_system(resolution, message: "alert", reason: "graphql cleared", needs_attention: false)

      refute_receive {:event, _envelope}, 200
    end

    defp ledger_records do
      AlertLedger.path()
      |> File.read()
      |> case do
        {:ok, contents} -> contents |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
        {:error, _missing} -> []
      end
    end

    defp ledger_topic_count(topic), do: Enum.count(ledger_records(), &(&1["topic"] == topic))
  end

  test "todo overload emits system.dispatch.todo_capacity_exceeded once per overload interval" do
    workspace_root =
      Aiur.TestSupport.tmp_root!("aiur-alert-overload")

    # Resolved via the issue identifier, so it must match the repo-namespaced
    # layout (Linear default config → <root>/project/<issue>).
    workspace = Path.join([workspace_root, "project", "MT-ALERT-3"])
    File.mkdir_p!(workspace)

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      max_concurrent_agents: 1
    )

    issues = [
      %Issue{id: "issue-1", identifier: "MT-ALERT-3", state: "Todo", title: "First"},
      %Issue{id: "issue-2", identifier: "MT-ALERT-4", state: "Todo", title: "Second"}
    ]

    state = %Orchestrator.State{}
    state = IssueSync.sync_todo_capacity_alert(state, issues)
    _state = IssueSync.sync_todo_capacity_alert(state, issues)

    log = Path.join(workspace, "logs/agent.ndjson") |> File.read!()

    assert String.split(log, "\"name\":\"system.dispatch.todo_capacity_exceeded\"") |> length() ==
             2
  end

  @tag :tmp_dir
  test "cause-scoped pause and unpaused alerts fire from control-state transitions", %{tmp_dir: workspace_root} do
    workspace = Path.join(workspace_root, "MT-ALERT-5")
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    orchestrator_name = Module.concat(__MODULE__, :PauseAlertOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn -> stop_orchestrator!(pid) end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-5" => %{
              pid: self(),
              ref: nil,
              identifier: "MT-ALERT-5",
              issue: %Issue{id: "issue-5", identifier: "MT-ALERT-5", state: "In Progress", title: "Pause"},
              workspace_path: workspace,
              worker_host: nil,
              control: %{can_interrupt: true, safe_checkpoints: [], status: :working},
              started_at: DateTime.utc_now()
            }
          }
      }
    end)

    log_path = Path.join(workspace, "logs/agent.ndjson")

    assert_eventually(
      fn ->
        send(pid, {:worker_control_state, "issue-5", :paused})
        Process.sleep(25)
        send(pid, {:worker_control_state, "issue-5", :working})

        if File.exists?(log_path) do
          log = File.read!(log_path)

          String.contains?(
            log,
            "\"name\":\"ticket.MT-ALERT-5.agent.attention.paused-worker_pause_unknown\""
          ) and
            String.contains?(log, "\"needs_attention\":true") and
            String.contains?(log, "\"severity\":\"warning\"") and
            String.contains?(log, "\"name\":\"ticket.MT-ALERT-5.agent.unpaused\"") and
            String.contains?(log, "\"reason\":\"Agent resumed; no Executor action is needed.\"") and
            String.contains?(log, "\"needs_attention\":false")
        else
          false
        end
      end,
      20
    )
  end

  @tag :tmp_dir
  test "operator-initiated resume emits an agent.unpaused alert at the orchestrator sync-flip", %{tmp_dir: workspace_root} do
    # Regression: `send_resume_control_message/2` sync-flips control.status
    # from :paused to :working before the worker's `:worker_control_state`
    # confirmation comes back. The later confirmation sees previous_status
    # already :working and emits no transition alert — so the orchestrator
    # must emit the unpause alert itself at the sync-flip point.
    workspace = Path.join(workspace_root, "MT-RESUME-SYNC")
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    orchestrator_name = Module.concat(__MODULE__, :ResumeSyncAlertOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn -> stop_orchestrator!(pid) end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-resume-sync" => %{
              pid: self(),
              ref: make_ref(),
              identifier: "MT-RESUME-SYNC",
              issue: %Issue{
                id: "issue-resume-sync",
                identifier: "MT-RESUME-SYNC",
                state: "In Progress",
                title: "Resume sync"
              },
              workspace_path: workspace,
              worker_host: nil,
              control: %{can_interrupt: true, safe_checkpoints: [], status: :paused},
              started_at: DateTime.utc_now()
            }
          }
      }
    end)

    log_path = Path.join(workspace, "logs/agent.ndjson")

    assert {:ok, :resumed} = Orchestrator.resume_agent(orchestrator_name, "MT-RESUME-SYNC")

    # Confirmation arrives after the sync-flip but the alert has
    # already been emitted; the duplicate confirmation must not double-fire.
    send(pid, {:worker_control_state, "issue-resume-sync", :working})

    assert_eventually(
      fn ->
        if File.exists?(log_path) do
          log = File.read!(log_path)
          unpaused_count = String.split(log, "\"name\":\"ticket.MT-RESUME-SYNC.agent.unpaused\"") |> length()
          # exactly one unpause alert recorded (split count is N+1 occurrences)
          unpaused_count == 2
        else
          false
        end
      end,
      20
    )
  end

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met in time")

  # The orchestrator traps exits, so `Process.exit(pid, :normal)` only queues
  # an `{:EXIT, _, :normal}` message and leaves it running. It then keeps
  # appending to the workspace log while the sibling `on_exit` removes that
  # directory, and under partition load `File.rm_rf!/1` fails with `:eexist`
  # on the tree still being written. Wait for the writer to actually be gone.
  defp stop_orchestrator!(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 -> flunk("orchestrator #{inspect(pid)} did not stop")
      end
    end
  end
end
