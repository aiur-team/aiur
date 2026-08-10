defmodule Aiur.AgentControlCLITest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.{AgentControlCLI, AlertLedger, Asks, BuildGate, Config, DispatchBudgetStore, RepoBase}
  alias Aiur.GitHub.CiReadiness
  alias Aiur.Orchestrator.State

  defp capture_todo(ids, opts) do
    parent = self()
    ref = make_ref()

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            send(parent, {ref, :exit_code, AgentControlCLI.todo(ids, opts)})
          end)

        send(parent, {ref, :stdout, stdout})
      end)

    assert_receive {^ref, :stdout, stdout}
    assert_receive {^ref, :exit_code, exit_code}
    {stdout, stderr, exit_code}
  end

  defp todo_config do
    %{
      queue_label: "sym:todo",
      active_states: ["todo", "working", "rework"],
      active_labels: ["sym:todo", "sym:working", "sym:rework"],
      terminal_labels: ["sym:done", "sym:cancelled"]
    }
  end

  defp todo_deps(issues, opts \\ []) do
    parent = self()
    active = Keyword.get(opts, :active, Map.values(issues))
    fetch_active_result = Keyword.get(opts, :fetch_active_result, {:ok, active})
    add_result = Keyword.get(opts, :add_result, fn _id, _label -> :ok end)
    remove_result = Keyword.get(opts, :remove_result, fn _id, _label -> :ok end)
    ensure_started_result = Keyword.get(opts, :ensure_started_result, :ok)

    %{
      ensure_started: fn -> ensure_started_result end,
      load_config: fn -> {:ok, Keyword.get(opts, :config, todo_config())} end,
      fetch_issue: fn id ->
        send(parent, {:todo_fetch_issue, id})

        case Map.fetch(issues, id) do
          {:ok, {:error, reason}} -> {:error, reason}
          {:ok, issue} -> {:ok, [issue]}
          :error -> {:ok, []}
        end
      end,
      fetch_active: fn states ->
        send(parent, {:todo_fetch_active, states})
        fetch_active_result
      end,
      add_label: fn id, label ->
        send(parent, {:todo_add_label, id, label})
        add_result.(id, label)
      end,
      remove_label: fn id, label ->
        send(parent, {:todo_remove_label, id, label})
        remove_result.(id, label)
      end
    }
  end

  defp running_entry(issue_id, identifier, status, pid \\ self()) do
    %{
      pid: pid,
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "In Progress", title: "Issue #{identifier}"},
      control: %{
        can_interrupt: true,
        safe_checkpoints: [:notification],
        status: status
      },
      session_id: "thread-#{identifier}",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp queued_issue(issue_id \\ "issue-queued") do
    %Issue{id: issue_id, identifier: "repo##{issue_id}", state: "In Progress", title: "Queued"}
  end

  # A running entry shaped for `watch` assertions: lets a test set the tracker
  # state, labels (for the complexity column), last activity timestamp (for age
  # / stuck detection) and last message (for the doing column).
  defp watch_entry(issue_id, identifier, opts) do
    issue_id
    |> running_entry(identifier, Keyword.get(opts, :work_state, :working))
    |> update_in([:issue], fn issue ->
      %{issue | state: Keyword.get(opts, :state, "in-progress"), labels: Keyword.get(opts, :labels, [])}
    end)
    |> Map.put(:last_codex_timestamp, Keyword.get(opts, :last_codex_timestamp))
    |> Map.put(:last_codex_message, Keyword.get(opts, :last_codex_message))
  end

  setup do
    pid = Process.whereis(Orchestrator)
    original_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{}, last_polled_issues: %{}, session_max_concurrent_agents: nil}
    end)

    on_exit(fn ->
      if Process.alive?(pid) do
        :sys.replace_state(pid, fn _state -> original_state end)
      end
    end)

    {:ok, orchestrator: pid}
  end

  describe "todo/2" do
    test "mutates the tracker and emits the control exit marker" do
      issue = %Issue{id: "issue-11", identifier: "11", state: "todo", title: "Queued"}

      {stdout, stderr, exit_code} =
        capture_todo(["11"],
          deps: todo_deps(%{"11" => issue}),
          emit_exit_marker: true
        )

      assert exit_code == 0
      assert stderr == ""
      assert stdout =~ "queued 1 ticket(s); cleared 0 other(s)"
      assert stdout =~ "__AIUR_CONTROL_EXIT__:0"
      assert_received {:todo_add_label, "11", "sym:todo"}
    end

    test "emits a failure marker when tracker mutation fails" do
      {stdout, stderr, exit_code} =
        capture_todo(["11"],
          deps: todo_deps(%{"11" => {:error, :unavailable}}),
          emit_exit_marker: true
        )

      assert exit_code == 1
      assert stderr =~ "orchestrator unavailable"
      assert stdout =~ "queued 0 ticket(s); cleared 0 other(s)"
      assert stdout =~ "__AIUR_CONTROL_EXIT__:1"
    end

    test "reports a stopped application without a summary or stacktrace" do
      {stdout, stderr, exit_code} =
        capture_todo(["123"], deps: todo_deps(%{}, ensure_started_result: {:error, :application_not_started}))

      assert exit_code == 1
      assert stdout == ""
      assert stderr == "error: aiur is not running. Start it with `aiurdev run` (or `aiurdev --bg`), then retry.\n"
      refute stderr =~ "GenServer"
    end

    test "queues requested tickets with config-derived labels and streaming feedback" do
      issues =
        Map.new(~w(11 12 13), fn id ->
          {id, %Issue{id: id, identifier: id, state: nil, labels: []}}
        end)

      {stdout, stderr, exit_code} = capture_todo(~w(11 12 13), deps: todo_deps(issues))

      assert exit_code == 0
      assert stderr == ""
      assert stdout =~ "✓ #11 → sym:todo"
      assert stdout =~ "✓ #12 → sym:todo"
      assert stdout =~ "✓ #13 → sym:todo"
      assert stdout =~ "queued 3 ticket(s); cleared 0 other(s)"
      assert_received {:todo_add_label, "11", "sym:todo"}
      assert_received {:todo_add_label, "12", "sym:todo"}
      assert_received {:todo_add_label, "13", "sym:todo"}
    end

    test "treats an existing todo as idempotent and preserves configured mid-flight states" do
      issues = %{
        "11" => %Issue{id: "11", identifier: "11", state: "todo", labels: ["sym:todo"]},
        "12" => %Issue{id: "12", identifier: "12", state: "working", labels: ["sym:working"]}
      }

      {stdout, stderr, exit_code} = capture_todo(~w(11 12), deps: todo_deps(issues))

      assert exit_code == 0
      assert stderr == ""
      assert stdout =~ "✓ #11 already sym:todo"
      assert stdout =~ "• #12 kept sym:working"
      assert stdout =~ "queued 1 ticket(s); cleared 0 other(s)"
      refute_received {:todo_add_label, _, _}
    end

    test "only clears custom todo labels from other pending tickets" do
      issues = %{
        "11" => %Issue{id: "11", identifier: "11", state: "todo", labels: ["sym:todo"]}
      }

      active = [
        issues["11"],
        %Issue{id: "20", identifier: "20", state: "todo", labels: ["sym:todo"]},
        %Issue{id: "21", identifier: "21", state: "working", labels: ["sym:working"]},
        %Issue{id: "22", identifier: "22", state: "done", labels: ["sym:todo", "sym:done"]}
      ]

      {stdout, stderr, exit_code} =
        capture_todo(["11"], deps: todo_deps(issues, active: active), only: true)

      assert exit_code == 0
      assert stderr == ""
      assert stdout =~ "– #20 cleared sym:todo"
      assert stdout =~ "queued 1 ticket(s); cleared 1 other(s)"
      assert_received {:todo_fetch_active, ["todo", "working", "rework"]}
      assert_received {:todo_remove_label, "20", "sym:todo"}
      refute_received {:todo_remove_label, "11", _}
      refute_received {:todo_remove_label, "21", _}
      refute_received {:todo_remove_label, "22", _}
    end

    test "continues requested IDs but fails closed before only cleanup" do
      issues = %{
        "12" => {:error, :timeout},
        "13" => %Issue{id: "13", identifier: "13", state: "Closed", labels: []},
        "14" => %Issue{id: "14", identifier: "14", state: "done", labels: ["sym:done"]},
        "15" => %Issue{id: "15", identifier: "15", state: nil, labels: []}
      }

      {stdout, stderr, exit_code} =
        capture_todo(~w(11 12 13 14 15), deps: todo_deps(issues), only: true)

      assert exit_code == 1
      assert stdout =~ "✓ #15 → sym:todo"
      assert stdout =~ "queued 1 ticket(s); cleared 0 other(s)"
      assert stderr =~ "✗ #11 not found"
      assert stderr =~ "✗ #12 orchestrator timed out"
      assert stderr =~ "✗ #13 terminal ticket"
      assert stderr =~ "✗ #14 terminal ticket"
      assert stderr =~ "--only cleanup skipped because 4 requested ticket(s) failed"
      assert_received {:todo_add_label, "15", "sym:todo"}
      refute_received {:todo_fetch_active, _}
    end

    test "continues requested IDs after an add failure and skips only cleanup" do
      issues =
        Map.new(~w(11 12), fn id ->
          {id, %Issue{id: id, identifier: id, state: nil, labels: []}}
        end)

      add_result = fn
        "11", "sym:todo" -> {:error, :timeout}
        _id, _label -> :ok
      end

      {stdout, stderr, exit_code} =
        capture_todo(~w(11 12), deps: todo_deps(issues, add_result: add_result), only: true)

      assert exit_code == 1
      assert stdout =~ "✓ #12 → sym:todo"
      assert stdout =~ "queued 1 ticket(s); cleared 0 other(s)"
      assert stderr =~ "✗ #11 failed to add sym:todo: orchestrator timed out"
      assert stderr =~ "--only cleanup skipped because 1 requested ticket(s) failed"
      assert_received {:todo_add_label, "11", "sym:todo"}
      assert_received {:todo_add_label, "12", "sym:todo"}
      refute_received {:todo_fetch_active, _}
    end

    test "reports active-ticket enumeration failures and exits non-zero" do
      issues = %{
        "11" => %Issue{id: "11", identifier: "11", state: "todo", labels: ["sym:todo"]}
      }

      {stdout, stderr, exit_code} =
        capture_todo(["11"],
          deps: todo_deps(issues, fetch_active_result: {:error, :timeout}),
          only: true
        )

      assert exit_code == 1
      assert stdout =~ "✓ #11 already sym:todo"
      assert stdout =~ "queued 1 ticket(s); cleared 0 other(s)"
      assert stderr =~ "aiur: failed to enumerate active tickets (orchestrator timed out)"
      assert_received {:todo_fetch_active, ["todo", "working", "rework"]}
      refute_received {:todo_remove_label, _, _}
    end

    test "continues clearing after a removal failure and exits non-zero" do
      issues = %{
        "11" => %Issue{id: "11", identifier: "11", state: "todo", labels: ["sym:todo"]}
      }

      active = [
        issues["11"],
        %Issue{id: "20", identifier: "20", state: "todo", labels: ["sym:todo"]},
        %Issue{id: "21", identifier: "21", state: "todo", labels: ["sym:todo"]}
      ]

      remove_result = fn
        "20", "sym:todo" -> {:error, :timeout}
        _id, _label -> :ok
      end

      {stdout, stderr, exit_code} =
        capture_todo(["11"], deps: todo_deps(issues, active: active, remove_result: remove_result), only: true)

      assert exit_code == 1
      assert stdout =~ "– #21 cleared sym:todo"
      assert stdout =~ "queued 1 ticket(s); cleared 1 other(s)"
      assert stderr =~ "✗ #20 failed to clear sym:todo: orchestrator timed out"
      assert_received {:todo_remove_label, "20", "sym:todo"}
      assert_received {:todo_remove_label, "21", "sym:todo"}
    end

    test "caps --only cleanup at a batch size and reports what was left untouched" do
      issues = %{
        "11" => %Issue{id: "11", identifier: "11", state: "todo", labels: ["sym:todo"]}
      }

      others =
        Enum.map(21..71, fn n ->
          id = to_string(n)
          %Issue{id: id, identifier: id, state: "todo", labels: ["sym:todo"]}
        end)

      active = [issues["11"] | others]

      {stdout, stderr, exit_code} =
        capture_todo(["11"], deps: todo_deps(issues, active: active), only: true)

      assert exit_code == 0
      assert stdout =~ "queued 1 ticket(s); cleared 50 other(s)"
      assert stderr =~ "aiur: --only cleanup capped at 50 ticket(s); 1 other ticket(s) left untouched"
      assert_received {:todo_remove_label, "70", "sym:todo"}
      refute_received {:todo_remove_label, "71", "sym:todo"}
    end

    test "stops --only cleanup after repeated rate-limit failures mid-stream" do
      issues = %{
        "11" => %Issue{id: "11", identifier: "11", state: "todo", labels: ["sym:todo"]}
      }

      active = [
        issues["11"],
        %Issue{id: "20", identifier: "20", state: "todo", labels: ["sym:todo"]},
        %Issue{id: "21", identifier: "21", state: "todo", labels: ["sym:todo"]},
        %Issue{id: "22", identifier: "22", state: "todo", labels: ["sym:todo"]},
        %Issue{id: "23", identifier: "23", state: "todo", labels: ["sym:todo"]}
      ]

      rate_limited = {:error, {:github, :rate_limited, %{status: 429, retry_after: 60, poll_interval: nil}}}

      remove_result = fn
        id, "sym:todo" when id in ["20", "21", "22"] -> rate_limited
        _id, _label -> :ok
      end

      {stdout, stderr, exit_code} =
        capture_todo(["11"], deps: todo_deps(issues, active: active, remove_result: remove_result), only: true)

      assert exit_code == 1
      assert stdout =~ "queued 1 ticket(s); cleared 0 other(s)"
      assert stderr =~ "aiur: --only cleanup stopped after 3 consecutive rate-limit failures"
      assert_received {:todo_remove_label, "20", "sym:todo"}
      assert_received {:todo_remove_label, "21", "sym:todo"}
      assert_received {:todo_remove_label, "22", "sym:todo"}
      refute_received {:todo_remove_label, "23", "sym:todo"}
    end
  end

  test "pause reports already paused agents as a successful no-op", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :paused)}}
    end)

    output = capture_io(fn -> AgentControlCLI.pause(["44"]) end)

    assert output =~ "aiur: already paused #44"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    refute_receive {:pause_agent, _request_id}, 100
  end

  test "status prints empty and populated tables", %{orchestrator: pid} do
    empty_output = capture_io(fn -> AgentControlCLI.status() end)

    assert empty_output =~ "ISSUE STATE  TITLE"
    assert empty_output =~ "(no active agents)"
    assert empty_output =~ "__AIUR_CONTROL_EXIT__:0"

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-44" => running_entry("issue-44", "repo#44", :working),
            "88" => running_entry("88", "", :working),
            "issue-alpha" => running_entry("issue-alpha", "worker-alpha", :working)
          }
      }
    end)

    populated_output = capture_io(fn -> AgentControlCLI.status() end)

    assert populated_output =~ "ISSUE STATE   TITLE"
    assert populated_output =~ "#44    running Issue repo#44"
    assert populated_output =~ "#88    running Issue "
    assert populated_output =~ "worker-alpha running Issue worker-alpha"
    assert populated_output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "status names awaiting dispatch and transient retry causes", %{orchestrator: pid} do
    idle = %Issue{id: "issue-17", identifier: "repo#17", state: "todo", title: "Awaiting dispatch"}
    retry = %Issue{id: "issue-18", identifier: "repo#18", state: "todo", title: "Retrying", labels: ["agent:todo", "agent:paused"], paused: true}
    due_at_ms = System.monotonic_time(:millisecond) + 240_000

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_polled_issues: %{idle.id => idle, retry.id => retry},
          retry_attempts: %{
            retry.id => %{
              identifier: retry.identifier,
              attempt: 1,
              due_at_ms: due_at_ms,
              error: "tracker 403"
            }
          }
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "#17    idle    Awaiting dispatch (awaiting-dispatch)"
    assert output =~ "#18    paused  Retrying (operator; transient: tracker 403, retry ~4m)"
  end

  test "status shows a durable lifetime latch after in-memory recovery state is lost", %{orchestrator: pid} do
    write_workflow_file_synced!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_dispatches_per_ticket: 40
    )

    issue_id = "issue-latched-status"
    issue = %Issue{id: issue_id, identifier: "repo#1712", state: "error", title: "Terminal latch"}
    maximum = Config.agent_max_dispatches_per_ticket()
    :ok = DispatchBudgetStore.put_lifetime(issue_id, maximum)

    on_exit(fn -> DispatchBudgetStore.reset(issue_id) end)

    :sys.replace_state(pid, fn state ->
      %{state | last_polled_issues: %{issue_id => issue}, dispatch_recovery: %State{}.dispatch_recovery}
    end)

    assert capture_io(fn -> AgentControlCLI.status() end) =~
             "#1712  idle    Terminal latch (latched #{maximum}/#{maximum})"
  end

  test "status names a tracker pause as operator-paused", %{orchestrator: pid} do
    paused = %Issue{
      id: "issue-19",
      identifier: "repo#19",
      state: "todo",
      title: "Operator pause",
      labels: ["agent:todo", "agent:paused"],
      paused: true
    }

    :sys.replace_state(pid, fn state ->
      %{state | last_polled_issues: %{paused.id => paused}}
    end)

    assert capture_io(fn -> AgentControlCLI.status() end) =~
             "#19    paused  Operator pause (operator)"
  end

  test "status includes the repository readiness line" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    parent = self()

    Application.put_env(:aiur, :ci_readiness_check_fun, fn _opts ->
      send(parent, :ci_readiness_checked)
      {:ok, %{ready?: false, base_branch: "main", issues: [:no_pr_workflow]}}
    end)

    CiReadiness.cache_result(%{ready?: false, base_branch: "main", issues: [:no_pr_workflow]})

    on_exit(fn ->
      Application.delete_env(:aiur, :ci_readiness_check_fun)
      CiReadiness.clear_cached_result()
    end)

    assert capture_io(fn -> AgentControlCLI.status() end) =~ "CI readiness: not ready for main"
    refute_receive :ci_readiness_checked
  end

  test "status reports unavailable before the dispatcher has a readiness result" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    CiReadiness.clear_cached_result()
    on_exit(&CiReadiness.clear_cached_result/0)

    assert capture_io(fn -> AgentControlCLI.status() end) =~ "CI readiness: unavailable"
  end

  test "status names the config cap and AIMD envelope binding constraints", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_concurrent_agents: 2,
          effective_concurrent_agents: 2,
          running: %{
            "issue-44" => running_entry("issue-44", "repo#44", :working),
            "issue-45" => running_entry("issue-45", "repo#45", :working)
          },
          last_polled_issues: %{"issue-queued" => queued_issue()}
      }
    end)

    config_output = capture_io(fn -> AgentControlCLI.status() end)
    assert config_output =~ "AGENTS 2/2 (binding: config max_concurrent_agents)"

    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_concurrent_agents: 2,
          effective_concurrent_agents: 1,
          running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)},
          last_polled_issues: %{"issue-queued" => queued_issue()}
      }
    end)

    envelope_output = capture_io(fn -> AgentControlCLI.status() end)
    assert envelope_output =~ "AGENTS 1/2 (binding: AIMD envelope, effective cap=1)"
  end

  test "status treats blocked tracker rows as ticket supply, not dispatch demand", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_concurrent_agents: 2,
          effective_concurrent_agents: 2,
          last_polled_issues: %{
            "issue-paused" => Map.put(queued_issue(), :paused, true),
            "issue-unauthorized" => Map.put(queued_issue("issue-unauthorized"), :dispatch_authorized?, false)
          }
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "AGENTS 0/2 (binding: ticket supply)"
  end

  test "status counts paused reservations as occupied capacity", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_concurrent_agents: 2,
          effective_concurrent_agents: 2,
          running: %{
            "issue-paused" =>
              running_entry("issue-paused", "repo#paused", :paused)
              |> Map.put(:paused_reason, :operator_pause),
            "issue-paused-two" =>
              running_entry("issue-paused-two", "repo#paused-two", :paused)
              |> Map.put(:paused_reason, :operator_pause)
          }
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "AGENTS 2/2 (binding: paused reservations=2)"
    refute output =~ "binding: ticket supply"
  end

  test "status does not blame paused reservations when the cap is already binding", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_concurrent_agents: 3,
          session_max_concurrent_agents: 1,
          effective_concurrent_agents: 1,
          running: %{
            "issue-active" => running_entry("issue-active", "repo#active", :working),
            "issue-paused" =>
              running_entry("issue-paused", "repo#paused", :paused)
              |> Map.put(:paused_reason, :operator_pause)
          },
          last_polled_issues: %{"issue-queued" => queued_issue()}
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "AGENTS 2/1 (binding: session max_concurrent_agents)"
    refute output =~ "paused reservations"
  end

  test "status uses a source-neutral session cap label", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_concurrent_agents: 3,
          session_max_concurrent_agents: 1,
          effective_concurrent_agents: 1,
          running: %{
            "issue-44" => running_entry("issue-44", "repo#44", :working)
          }
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "AGENTS 1/1 (binding: session max_concurrent_agents)"
    refute output =~ "requested CLI cap"
  end

  test "status prints the resolved CODEOWNERS trust snapshot", %{orchestrator: pid} do
    path = Path.join(File.cwd!(), ".github/CODEOWNERS")

    Application.put_env(:aiur, :agent_control_cli_trust_snapshot_fun, fn ->
      %{trusted: ["its-applekid", "its-everdred"], source: :file, path: path}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_trust_snapshot_fun) end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "COMMENT TRUST source=file trusted=[@its-applekid, @its-everdred] path=.github/CODEOWNERS"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    assert Process.alive?(pid)
  end

  test "status reports active build-gate contention", %{orchestrator: pid} do
    gate_dir = Path.join(System.tmp_dir!(), "aiur-build-gate-status-#{System.unique_integer([:positive])}")
    lock_dir = BuildGate.lock_dir(gate_dir)
    previous = Application.get_env(:aiur, :build_gate_dir_override)
    release_path = Path.join(gate_dir, "holder.release")
    slot_lock = Path.join(lock_dir, "slot-1.lock")
    slot_owner = Path.join(gate_dir, "slot-1.owner")
    queue_path = Path.join(gate_dir, "queue/lease-v2-status")
    metadata = "version=2\ntoken=status\npid=2\npgid=1\nphase=test\ncommand=test\n"

    Application.put_env(:aiur, :build_gate_dir_override, gate_dir)
    assert {:ok, _canonical_gate_dir} = BuildGate.prepare_writable_root(gate_dir: gate_dir, slots: 2)
    File.mkdir_p!(Path.join(gate_dir, "queue"))
    File.write!(slot_owner, metadata)
    File.write!(queue_path, metadata)

    bash = System.find_executable("bash") || flunk("bash is required for build-gate status tests")

    holder =
      Port.open({:spawn_executable, String.to_charlist(bash)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "-c",
          ~S"""
          exec 8<>"$1"
          flock 8
          exec 9<>"$2"
          flock 9
          printf 'ready\n'
          while [[ ! -e $3 ]]; do sleep 0.05; done
          """,
          "build-gate-holder",
          slot_lock,
          queue_path,
          release_path
        ]
      ])

    assert_receive {^holder, {:data, "ready\n"}}, 2_000

    on_exit(fn ->
      File.touch!(release_path)
      if Port.info(holder), do: Port.close(holder)

      if is_nil(previous) do
        Application.delete_env(:aiur, :build_gate_dir_override)
      else
        Application.put_env(:aiur, :build_gate_dir_override, previous)
      end

      File.rm_rf!(gate_dir)
      File.rm_rf!(lock_dir)
    end)

    assert %{active: 1, queued: 1} = BuildGate.status()

    :sys.replace_state(pid, fn state ->
      issue = %Issue{id: "issue-idle", identifier: "repo#idle", state: "In Progress", title: "Idle"}
      %{state | last_polled_issues: %{"issue-idle" => issue}}
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)
    assert output =~ "AGENTS 0/10 (binding: none)"
    assert output =~ "BUILD GATE 1/2 active, 1 queued"
    File.touch!(release_path)
    assert_receive {^holder, {:exit_status, 0}}, 2_000
  end

  test "status reports actionable legacy build-gate degradation" do
    gate_dir = Path.join(System.tmp_dir!(), "aiur-build-gate-legacy-#{System.unique_integer([:positive])}")
    lock_dir = BuildGate.lock_dir(gate_dir)
    previous = Application.get_env(:aiur, :build_gate_dir_override)
    legacy_path = Path.join(gate_dir, "slot-1")

    Application.put_env(:aiur, :build_gate_dir_override, gate_dir)
    assert {:ok, _canonical_gate_dir} = BuildGate.prepare_writable_root(gate_dir: gate_dir, slots: 2)
    File.write!(legacy_path, "pid=2\npgid=1\ncommand=test\n")

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:aiur, :build_gate_dir_override)
      else
        Application.put_env(:aiur, :build_gate_dir_override, previous)
      end

      File.rm_rf!(gate_dir)
      File.rm_rf!(lock_dir)
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)
    assert output =~ "BUILD GATE DEGRADED 0/2 active, 0 queued"
    assert output =~ "reason=legacy_state path=#{legacy_path}"
    assert output =~ "recovery=repair the configured build-gate directory"
  end

  describe "prewarm status surface" do
    # Prewarm-enabled config for the CLI surface tests. No `base_build` and a
    # memory tracker keep RepoBase's own resolve/poll inert (no clone/build can
    # start) while `Config.prewarm_enabled?/0` reads true.
    defp with_prewarm_enabled do
      tmp = Path.join(System.tmp_dir!(), "cli_prewarm_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      cfg = Path.join(tmp, "config")
      File.write!(cfg, "tracker:\n  kind: memory\nprewarm:\n  enabled: true\n  poll_seconds: 0\n")
      previous = Application.get_env(:aiur, :workflow_file_path)
      Aiur.Workflow.set_workflow_file_path(cfg)

      on_exit(fn ->
        case previous do
          nil -> Aiur.Workflow.clear_workflow_file_path()
          path -> Aiur.Workflow.set_workflow_file_path(path)
        end
      end)

      :ok
    end

    # Drive the live RepoBase phase so `aiur status` renders the prewarm line
    # exactly as it would against a warming/errored base.
    defp with_repo_base_phase(phase) do
      pid = Process.whereis(RepoBase) || flunk("RepoBase must be running for prewarm status tests")
      original = :sys.get_state(pid)

      :sys.replace_state(pid, fn state -> %{state | phase: phase, base_path: "/tmp/base"} end)

      on_exit(fn -> restore_repo_base(pid, original) end)

      :ok
    end

    defp restore_repo_base(pid, original) do
      if Process.alive?(pid), do: :sys.replace_state(pid, fn _state -> original end)
    end

    test "status surfaces prewarm: warming while the base build is in flight" do
      with_prewarm_enabled()
      with_repo_base_phase(:building)

      output = capture_io(fn -> AgentControlCLI.status() end)
      assert output =~ "PREWARM prewarm: warming phase=building"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "status surfaces a failed base build as a cold-clone fallback" do
      with_prewarm_enabled()
      with_repo_base_phase({:error, :base_build_failed})

      output = capture_io(fn -> AgentControlCLI.status() end)
      assert output =~ "PREWARM prewarm: unavailable"
      assert output =~ "dispatching via cold clone"
    end

    test "status stays silent for a ready base and when prewarm is disabled" do
      # Default fixture config has prewarm disabled.
      disabled_output = capture_io(fn -> AgentControlCLI.status() end)
      refute disabled_output =~ "PREWARM"

      with_prewarm_enabled()
      with_repo_base_phase(:ready)
      ready_output = capture_io(fn -> AgentControlCLI.status() end)
      refute ready_output =~ "PREWARM"
    end
  end

  test "status hides closed cached issues and deactivated runtime entries", %{orchestrator: pid} do
    active = %Issue{id: "issue-active", identifier: "repo#44", state: "In Progress", title: "Active"}

    closed_stale_label = %Issue{
      id: "issue-closed-stale-label",
      identifier: "repo#523",
      state: "Closed",
      title: "Closed stale active label",
      labels: ["agent:human-review"]
    }

    closed_unlabeled = %Issue{
      id: "issue-closed-unlabeled",
      identifier: "repo#524",
      state: nil,
      title: "Closed with active label removed"
    }

    deactivated =
      "issue-deactivated"
      |> running_entry("repo#491", :deactivated)
      |> put_in([:issue, Access.key(:title)], "Deactivated")

    closed_running =
      "issue-closed-running"
      |> running_entry("repo#492", :working)
      |> update_in([:issue], &%{&1 | state: "Closed", title: "Closed running"})

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_polled_issues: %{
            "issue-active" => active,
            "issue-closed-stale-label" => closed_stale_label,
            "issue-closed-unlabeled" => closed_unlabeled
          },
          running: %{
            "issue-active" => running_entry("issue-active", "repo#44", :working),
            "issue-deactivated" => deactivated,
            "issue-closed-running" => closed_running
          }
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "#44    running Issue repo#44"
    refute output =~ "#491"
    refute output =~ "#492"
    refute output =~ "#523"
    refute output =~ "#524"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "all targets report empty successful selections" do
    pause_output = capture_io(fn -> AgentControlCLI.pause(:all) end)
    resume_output = capture_io(fn -> AgentControlCLI.resume(:all) end)

    assert pause_output =~ "aiur: no running agents"
    assert pause_output =~ "__AIUR_CONTROL_EXIT__:0"
    assert resume_output =~ "aiur: no paused agents"
    assert resume_output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  describe "reset-budget" do
    test "queues the lifetime dispatch reset without a status lookup", %{orchestrator: pid} do
      issue = %Issue{id: "issue-49", identifier: "repo#49", state: "error", title: "Latched"}
      :ok = DispatchBudgetStore.put_lifetime(issue.id, 40)

      :sys.replace_state(pid, fn state ->
        state = put_in(state.dispatch_recovery.codex_thrash_budget[issue.id], %{lifetime: 40, count: 0})
        %{state | running: %{}, last_polled_issues: %{issue.id => issue}}
      end)

      output = capture_io(fn -> AgentControlCLI.reset_budget(["49"]) end)

      assert output =~ "aiur: queued lifetime dispatch budget reset for #49"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"

      # Barrier behind the cast: the bare issue number was resolved inside the
      # orchestrator, without a blocking CLI status request.
      state = :sys.get_state(pid)
      assert get_in(state.dispatch_recovery.codex_thrash_budget, [issue.id]) == nil
      assert {:ok, 0} = DispatchBudgetStore.lifetime(issue.id)
    end

    test "reports an unknown issue as queued rather than timing out", %{orchestrator: pid} do
      output = capture_io(fn -> AgentControlCLI.reset_budget(["9999"]) end)

      assert output =~ "aiur: queued lifetime dispatch budget reset for #9999"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
      _state = :sys.get_state(pid)
    end
  end

  describe "global pause switch" do
    test "pause_global halts the daemon and resume_global lifts it", %{orchestrator: pid} do
      :sys.replace_state(pid, fn state -> %{state | globally_paused: false} end)

      pause_output = capture_io(fn -> AgentControlCLI.pause_global() end)
      assert pause_output =~ "aiur: global pause ON"
      assert pause_output =~ "__AIUR_CONTROL_EXIT__:0"
      assert :sys.get_state(pid).globally_paused

      resume_output = capture_io(fn -> AgentControlCLI.resume_global() end)
      assert resume_output =~ "aiur: global pause OFF"
      assert resume_output =~ "__AIUR_CONTROL_EXIT__:0"
      refute :sys.get_state(pid).globally_paused
    end

    test "status surfaces the global pause banner only while paused", %{orchestrator: pid} do
      :sys.replace_state(pid, fn state -> %{state | globally_paused: true} end)
      assert capture_io(fn -> AgentControlCLI.status() end) =~ "GLOBALLY PAUSED"

      :sys.replace_state(pid, fn state -> %{state | globally_paused: false} end)
      refute capture_io(fn -> AgentControlCLI.status() end) =~ "GLOBALLY PAUSED"
    end

    test "targeted controls fail truthfully while globally paused", %{orchestrator: pid} do
      :sys.replace_state(pid, fn state -> %{state | globally_paused: true} end)

      stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)
          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      assert stderr =~ "error: aiur is globally paused; per-ticket resume has no effect."
      assert stderr =~ "Run `aiurdev resume` (no arguments) to lift the global pause."
    end
  end

  test "pause and resume emit control messages and successful summaries", %{orchestrator: pid} do
    parent = self()

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working, parent)}}
    end)

    pause_output = capture_io(fn -> AgentControlCLI.pause(["44"]) end)

    assert pause_output =~ "aiur: paused #44 (was: running)"
    assert pause_output =~ "__AIUR_CONTROL_EXIT__:0"
    assert_receive {:pause_agent, pause_request_id} when is_integer(pause_request_id), 500

    send(pid, {:worker_control_state, "issue-44", :paused})

    assert [%{identifier: "repo#44", state: :paused}] = Orchestrator.status(Orchestrator, 1_000)

    resume_output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)

    assert resume_output =~ "aiur: resumed #44 (was: paused)"
    assert resume_output =~ "__AIUR_CONTROL_EXIT__:0"
    assert_receive {:resume_agent, resume_request_id} when is_integer(resume_request_id), 500
  end

  test "mixed target results exit successfully when at least one target works", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :paused)}}
    end)

    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.pause(["44", "45"]) end)

        assert output =~ "aiur: already paused #44"
        assert output =~ "__AIUR_CONTROL_EXIT__:0"
      end)

    assert stderr =~ "aiur: failed to pause #45 (no running agent)"
  end

  test "all failed targets exit non-zero" do
    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume(["45"]) end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "aiur: failed to resume #45 (no running agent)"
  end

  test "running resume is a successful no-op", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
    end)

    output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)

    assert output =~ "aiur: already running #44"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "idle resume starts queued issues", %{orchestrator: pid} do
    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "repo#47" -> {:ok, :started} end)

    on_exit(fn ->
      Application.delete_env(:aiur, :agent_control_cli_resume_fun)
    end)

    issue = %Issue{id: "issue-47", identifier: "repo#47", state: "In Progress", title: "Queued"}

    :sys.replace_state(pid, fn state ->
      %{state | running: %{}, last_polled_issues: %{"issue-47" => issue}, session_max_concurrent_agents: 1}
    end)

    output = capture_io(fn -> AgentControlCLI.resume(["47"]) end)

    assert output =~ "aiur: started #47 (was: idle)"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "idle resume reports non-resumable issues", %{orchestrator: pid} do
    issue = %Issue{id: "issue-48", identifier: "repo#48", state: "Done", title: "Closed"}

    :sys.replace_state(pid, fn state ->
      %{state | running: %{}, last_polled_issues: %{"issue-48" => issue}}
    end)

    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume(["48"]) end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "aiur: failed to resume #48 (not resumable)"
  end

  test "fallback display handles nil targets" do
    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume([nil]) end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "aiur: failed to resume  (no running agent)"
  end

  test "control failures format orchestrator reasons", %{orchestrator: pid} do
    dead_pid = spawn(fn -> :ok end)
    ref = Process.monitor(dead_pid)
    assert_receive {:DOWN, ^ref, :process, ^dead_pid, _reason}, 500

    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 1,
          running: %{
            "issue-active" => running_entry("issue-active", "repo#44", :working),
            "issue-dead" => running_entry("issue-dead", "repo#45", :working, dead_pid),
            "issue-paused" => running_entry("issue-paused", "repo#46", :paused)
          }
      }
    end)

    pause_stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.pause(["45"]) end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    resume_stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume(["46"]) end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert pause_stderr =~ "aiur: failed to pause #45 (agent finished)"
    assert resume_stderr =~ "aiur: failed to resume #46 (max concurrent agents reached)"
  end

  test "message delivers operator text to a running agent and reports success", %{orchestrator: pid} do
    parent = self()

    Application.put_env(:aiur, :agent_control_cli_message_fun, fn identifier, text ->
      send(parent, {:messaged, identifier, text})
      {:ok, 7}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_message_fun) end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
    end)

    output = capture_io(fn -> AgentControlCLI.message("44", "ship it") end)

    assert output =~ "aiur: messaged #44"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    # Delivered through the canonical identifier, not the bare issue number.
    assert_receive {:messaged, "repo#44", "ship it"}, 500
  end

  test "message to a non-running issue fails with a clear error" do
    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.message("45", "hello") end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "aiur: failed to message #45 (no running agent)"
  end

  test "message surfaces delivery errors with a non-zero exit", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_message_fun) end)

    for {reason, expected} <- [
          {:empty_message, "message is empty"},
          {:message_too_long, "message is too long"},
          {:invalid_message, "invalid message"}
        ] do
      Application.put_env(:aiur, :agent_control_cli_message_fun, fn _identifier, _text ->
        {:error, reason}
      end)

      stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.message("44", "anything") end)

          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      assert stderr =~ "aiur: failed to message #44 (#{expected})"
    end
  end

  test "message reports a clear error when the orchestrator is unavailable", %{orchestrator: pid} do
    Process.unregister(Orchestrator)

    try do
      stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.message("44", "hi") end)

          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      assert stderr =~ "aiur: orchestrator is not running"
    after
      Process.register(pid, Orchestrator)
    end
  end

  test "unavailable orchestrator returns clear errors", %{orchestrator: pid} do
    Process.unregister(Orchestrator)

    try do
      status_stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.status() end)

          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      pause_stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.pause(["44"]) end)

          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      assert status_stderr =~ "aiur: orchestrator is not running"
      assert pause_stderr =~ "aiur: orchestrator is not running"
    after
      Process.register(pid, Orchestrator)
    end
  end

  describe "agents/0" do
    test "prints empty table when no agents are running" do
      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "ISSUE  STATE      RUNTIME  ACTIVITY"
      assert output =~ "(no active agents)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "prints one line per agent with state and current activity", %{orchestrator: pid} do
      active =
        "issue-44"
        |> running_entry("repo#44", :working)
        |> Map.merge(%{
          started_at: DateTime.add(DateTime.utc_now(), -90, :second),
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: "command_execution",
          last_codex_message: "running mix test"
        })

      paused =
        "issue-88"
        |> running_entry("repo#88", :paused)
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          last_codex_message: nil
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-44" => active, "issue-88" => paused}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#44"
      assert output =~ "working"
      # Activity prefers the latest event name; runtime renders compactly.
      assert output =~ "command_execution"
      assert output =~ "1m"
      # A paused agent shows its work-state instead of stale activity text.
      assert output =~ "#88"
      assert output =~ "(paused)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "shows label override as the pause reason", %{orchestrator: pid} do
      paused =
        "issue-46"
        |> running_entry("repo#46", :paused)
        |> update_in([:issue], &%{&1 | paused: true})
        |> Map.merge(%{
          paused_reason: :label_override,
          codex_app_server_pid: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          last_codex_message: nil
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-46" => paused}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#46"
      assert output =~ "(paused: label override)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "falls back to last_codex_message, then to a placeholder, and collapses long activity", %{orchestrator: pid} do
      base = fn id, ident -> id |> running_entry(ident, :working) |> Map.merge(%{codex_app_server_pid: nil, last_codex_timestamp: nil}) end

      # event nil -> fall back to message; multi-line + >80 chars -> single line, truncated.
      long = "tool\noutput " <> String.duplicate("x", 120)

      msg_only = base.("issue-1", "repo#1") |> Map.merge(%{last_codex_event: nil, last_codex_message: long})
      idle = base.("issue-2", "repo#2") |> Map.merge(%{last_codex_event: nil, last_codex_message: nil})

      deactivated =
        "issue-3"
        |> running_entry("repo#3", :deactivated)
        |> Map.merge(%{codex_app_server_pid: nil, last_codex_timestamp: nil, last_codex_event: nil, last_codex_message: nil})

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-1" => msg_only, "issue-2" => idle, "issue-3" => deactivated}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      # Activity is collapsed to a single line and ellipsis-truncated.
      assert output =~ "tool output xxx"
      refute output =~ "tool\noutput"
      assert output =~ "…"
      # No-activity and deactivated placeholders render.
      assert output =~ "(no activity yet)"
      assert output =~ "(deactivated)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "formats structured codex activity maps without crashing", %{orchestrator: pid} do
      activity = %{
        event: :notification,
        message: %{
          "method" => "account/rateLimits/updated",
          "params" => %{
            "rateLimits" => %{
              "credits" => %{"hasCredits" => true, "unlimited" => false},
              "limitId" => "codex",
              "planType" => "business"
            }
          }
        },
        timestamp: DateTime.utc_now()
      }

      active =
        "issue-44"
        |> running_entry("repo#44", :working)
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: :notification,
          last_codex_message: activity
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-44" => active}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#44"
      assert output =~ "rate limits updated"
      refute output =~ ~r/#44\s+working\s+\S+\s+notification/
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "formats codex activity maps wrapped in payload fields", %{orchestrator: pid} do
      activity = %{
        event: :notification,
        message: %{
          payload: %{
            "method" => "item/started",
            "params" => %{"item" => %{"type" => "reasoning", "id" => "rs_1234567890abcdef"}}
          }
        },
        timestamp: DateTime.utc_now()
      }

      active =
        "issue-45"
        |> running_entry("repo#45", :working)
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: :notification,
          last_codex_message: activity
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-45" => active}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#45"
      assert output =~ "item started: reasoning"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "formats structured codex activity when the event itself is a map", %{orchestrator: pid} do
      activity = %{
        event: :notification,
        message: %{
          "method" => "item/started",
          "params" => %{"item" => %{"type" => "reasoning", "content" => [], "summary" => []}}
        },
        timestamp: DateTime.utc_now()
      }

      active =
        "issue-46"
        |> running_entry("repo#46", :working)
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: activity,
          last_codex_message: nil
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-46" => active}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#46"
      assert output =~ "item started: reasoning"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "inspects unexpected non-string activity without crashing", %{orchestrator: pid} do
      active =
        "issue-47"
        |> running_entry("repo#47", :working)
        |> Map.merge(%{
          codex_app_server_pid: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: {:unexpected, %{payload: make_ref()}},
          last_codex_message: nil
        })

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-47" => active}}
      end)

      output = capture_io(fn -> AgentControlCLI.agents() end)

      assert output =~ "#47"
      assert output =~ "{:unexpected,"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "reports a clear error when the orchestrator is unavailable", %{orchestrator: pid} do
      Process.unregister(Orchestrator)

      try do
        stderr =
          capture_io(:stderr, fn ->
            output = capture_io(fn -> AgentControlCLI.agents() end)
            assert output =~ "__AIUR_CONTROL_EXIT__:1"
          end)

        assert stderr =~ "aiur: orchestrator is not running"
      after
        Process.register(pid, Orchestrator)
      end
    end
  end

  describe "alerts/1" do
    test "alerts and watch use the default project ledger" do
      log_root = Path.join(System.tmp_dir!(), "aiur-default-alert-ledger-#{System.unique_integer([:positive])}")
      previous_log_file = Application.get_env(:aiur, :log_file)
      Application.put_env(:aiur, :log_file, Path.join(log_root, "daemon.log"))

      on_exit(fn ->
        if previous_log_file,
          do: Application.put_env(:aiur, :log_file, previous_log_file),
          else: Application.delete_env(:aiur, :log_file)

        File.rm_rf!(log_root)
      end)

      ledger = AlertLedger.path()
      File.mkdir_p!(Path.dirname(ledger))

      File.write!(ledger, "{\"event\":\"alert\",\"topic\":\"ticket.51.agent.paused\",\"reason\":\"operator paused the agent\",\"needs_attention\":true,\"source_ticket_id\":\"51\",\"agent\":\"51\"}\n")

      assert capture_io(fn -> AgentControlCLI.alerts(needs_attention: true) end) =~ "ticket.51.agent.paused"

      assert capture_io(fn -> AgentControlCLI.watch(mode: :full, blocking_asks: []) end) =~
               "#51"
    end

    test "prints persisted alerts as JSON lines with optional attention filtering" do
      workspace_root =
        Path.join(System.tmp_dir!(), "aiur-control-alerts-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(workspace_root) end)
      write_workflow_file!(Aiur.Workflow.workflow_file_path(), workspace_root: workspace_root)

      log = Path.join(workspace_root, "repo/51/logs/agent.ndjson")
      File.mkdir_p!(Path.dirname(log))

      File.write!(log, """
      {"event":"alert","timestamp":"2026-06-25T01:00:00Z","name":"ticket.51.agent.phase.work.start","message":"work","reason":"work phase started","needs_attention":false}
      {"event":"alert","timestamp":"2026-06-25T01:01:00Z","name":"ticket.51.agent.paused","message":"paused","reason":"operator paused the agent","severity":"warning","needs_attention":true,"source_ticket_id":"51"}
      """)

      ledger = Path.join(workspace_root, "ledger.ndjson")

      File.write!(ledger, """
      {"event":"alert","timestamp":"2026-06-25T01:01:00Z","name":"ticket.51.agent.paused","message":"paused","reason":"operator paused the agent","severity":"warning","needs_attention":true,"source_ticket_id":"51"}
      """)

      output = capture_io(fn -> AgentControlCLI.alerts(needs_attention: true, ledger_paths: [ledger]) end)

      assert output =~ "\"topic\":\"ticket.51.agent.paused\""
      assert output =~ "\"reason\":\"operator paused the agent\""
      assert output =~ "\"needs_attention\":true"
      refute output =~ "phase.work.start"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end
  end

  describe "set_max_agents/1" do
    test "sets the cap and reports the new limit", %{orchestrator: pid} do
      :sys.replace_state(pid, fn state -> %{state | session_max_concurrent_agents: nil} end)

      output = capture_io(fn -> AgentControlCLI.set_max_agents(3) end)

      assert output =~ "aiur: max-agents set to 3 (0 active)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
      assert %{max: 3, session_override?: true} = Orchestrator.max_concurrent_agents(pid)
    end

    test "allows a cap below the active agent count and reports draining", %{orchestrator: pid} do
      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{
              "issue-1" => running_entry("issue-1", "repo#1", :working),
              "issue-2" => running_entry("issue-2", "repo#2", :working)
            }
        }
      end)

      output = capture_io(fn -> AgentControlCLI.set_max_agents(1) end)

      assert output =~ "aiur: max-agents set to 1 (2 active, draining)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "rejects a non-positive cap without touching the orchestrator" do
      stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.set_max_agents(0) end)
          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      assert stderr =~ "must be a positive integer"
    end
  end

  describe "watch" do
    setup do
      :persistent_term.erase({Aiur.AgentControlCLI, :watch_baseline})

      root = Path.join(System.tmp_dir!(), "aiur-watch-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, watch_root: root}
    end

    test "full board renders state, complexity, and activity per agent", %{orchestrator: pid, watch_root: root} do
      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{
              "issue-44" =>
                watch_entry("issue-44", "repo#44",
                  state: "in-progress",
                  labels: ["agent:in-progress", "complexity:3"],
                  last_codex_message: "running mix test"
                )
            }
        }
      end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ "TICKET  STATE         CX  AGE     DOING"
      assert output =~ ~r/#44\s+in-progress\s+3\s/
      assert output =~ "running mix test"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "status and watch surface persisted open blocking operator asks", %{watch_root: root} do
      asks_root = Path.join(System.tmp_dir!(), "aiur-status-asks-#{System.unique_integer([:positive])}")
      previous_root = Application.get_env(:aiur, :repo_base_root)
      Application.put_env(:aiur, :repo_base_root, asks_root)

      on_exit(fn ->
        if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
        File.rm_rf!(asks_root)
      end)

      write_workflow_file_synced!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")

      assert {:ok, ask} =
               Asks.create("owner/repo", %{
                 title: "Enable CI readiness inspection",
                 urgency: "high",
                 blocking: true
               })

      status = capture_io(fn -> AgentControlCLI.status() end)
      assert status =~ "OPERATOR ASKS (blocking)"
      assert status =~ ask["id"]
      assert status =~ "from executor at #{ask["created_at"]}"

      watch = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)
      assert watch =~ "ACTIONABLE"
      assert watch =~ "BLOCKING ASK #{ask["id"]}"
      assert watch =~ "Enable CI readiness inspection"

      assert {:ok, _} = Asks.resolve("owner/repo", ask["id"])
      refute capture_io(fn -> AgentControlCLI.status() end) =~ ask["id"]
      refute capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end) =~ ask["id"]
    end

    test "status and watch make an unreadable operator ask store actionable", %{watch_root: root} do
      asks_root = Path.join(System.tmp_dir!(), "aiur-status-asks-#{System.unique_integer([:positive])}")
      previous_root = Application.get_env(:aiur, :repo_base_root)
      Application.put_env(:aiur, :repo_base_root, asks_root)

      on_exit(fn ->
        if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
        File.rm_rf!(asks_root)
      end)

      write_workflow_file_synced!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
      :ok = RepoBase.ensure_state_tree("owner/repo")

      File.write!(
        RepoBase.asks_path("owner/repo"),
        Jason.encode!(%{
          "id" => "ask_orphan",
          "status" => "done",
          "resolved_at" => "2026-08-08T12:00:00Z",
          "resolved_by" => "executor",
          "note" => nil
        }) <> "\n"
      )

      status = capture_io(fn -> AgentControlCLI.status() end)
      assert status =~ "OPERATOR ASKS (blocking) UNAVAILABLE"
      assert status =~ "could not read durable ask record 1"
      assert status =~ "orphan_done"

      watch = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)
      assert watch =~ "ACTIONABLE"
      assert watch =~ "BLOCKING ASKS UNAVAILABLE"
    end

    test "empty board reports no active agents", %{watch_root: root} do
      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ "(no active agents)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "full board puts the global pause banner before the table", %{orchestrator: pid, watch_root: root} do
      :sys.replace_state(pid, fn state -> %{state | globally_paused: true, global_pause: %{paused_at: nil, source: "dashboard"}} end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ "GLOBALLY PAUSED (set by dashboard)"
      assert String.starts_with?(output, "GLOBALLY PAUSED")
    end

    test "full board surfaces prewarm: warming while the base warms", %{watch_root: root} do
      with_prewarm_enabled()
      with_repo_base_phase(:building)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ "PREWARM prewarm: warming phase=building"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "full board shows paused label override for idle active-state tickets", %{
      orchestrator: pid,
      watch_root: root
    } do
      :sys.replace_state(pid, fn state ->
        %{
          state
          | last_polled_issues: %{
              "issue-46" => %Issue{
                id: "issue-46",
                identifier: "repo#46",
                state: "todo",
                title: "Paused todo",
                paused: true,
                labels: ["agent:todo", "agent:paused", "complexity:2"]
              }
            }
        }
      end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ ~r/#46\s+paused\s+2\s/
      assert output =~ "(paused: operator)"
    end

    test "watch shows paused retry causes and reports a reason-only change", %{orchestrator: pid, watch_root: root} do
      retry = %Issue{
        id: "issue-47",
        identifier: "repo#47",
        state: "todo",
        title: "Retrying",
        paused: true,
        labels: ["agent:todo", "agent:paused"]
      }

      due_at_ms = System.monotonic_time(:millisecond) + 240_000

      set_retry = fn error ->
        :sys.replace_state(pid, fn state ->
          %{
            state
            | last_polled_issues: %{retry.id => retry},
              retry_attempts: %{
                retry.id => %{identifier: retry.identifier, attempt: 1, due_at_ms: due_at_ms, error: error}
              }
          }
        end)
      end

      set_retry.("tracker 403")
      first = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)
      assert first =~ "(paused: operator; transient: tracker 403, retry ~4m)"

      set_retry.("provider unavailable")
      changed = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)
      assert changed =~ "#47"
      assert changed =~ "(paused: operator; transient: provider unavailable, retry ~4m)"
    end

    test "changes mode prints a row once, then only when its state shifts", %{orchestrator: pid, watch_root: root} do
      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-44" => watch_entry("issue-44", "repo#44", state: "in-progress")}}
      end)

      first = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)
      assert first =~ "#44"

      second = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)
      assert second =~ "(no changes)"
      refute second =~ "#44"

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-44" => watch_entry("issue-44", "repo#44", state: "rework")}}
      end)

      third = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)
      assert third =~ "#44"
      assert third =~ "rework"
    end

    test "changes mode diffs each agent independently", %{orchestrator: pid, watch_root: root} do
      both = fn s45 ->
        %{
          "issue-44" => watch_entry("issue-44", "repo#44", state: "in-progress"),
          "issue-45" => watch_entry("issue-45", "repo#45", state: s45)
        }
      end

      :sys.replace_state(pid, fn state -> %{state | running: both.("in-progress")} end)
      _first = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)

      # Only #45 shifts state; #44 holds steady.
      :sys.replace_state(pid, fn state -> %{state | running: both.("rework")} end)
      second = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)

      assert second =~ "#45"
      assert second =~ "rework"
      refute second =~ "#44"
    end

    test "actionable section flags stuck agents and PR-ready tickets", %{orchestrator: pid, watch_root: root} do
      stale_ts = DateTime.add(DateTime.utc_now(), -1_200, :second)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{
              "issue-44" =>
                watch_entry("issue-44", "repo#44",
                  state: "in-progress",
                  last_codex_timestamp: stale_ts,
                  last_codex_message: "compiling"
                ),
              "issue-45" => watch_entry("issue-45", "repo#45", state: "human-review")
            }
        }
      end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ "ACTIONABLE"
      assert output =~ ~r/#44 stuck/
      assert output =~ ~r/#45 human-review · needs review\/merge/
    end

    test "actionable section surfaces an unanswered operator-decision question", %{watch_root: root} do
      ledger = Path.join(root, "ledger.ndjson")

      File.write!(
        ledger,
        Jason.encode!(%{
          "event" => "alert",
          "name" => "ticket.934.agent.attention.scope-question",
          "topic" => "ticket.934.agent.attention.scope-question",
          "message" => "Executor decision required",
          "reason" => "Executor decision required: Should this facade target change?",
          "severity" => "warning",
          "needs_attention" => true,
          "source_ticket_id" => "934",
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        }) <> "\n"
      )

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, ledger_paths: [ledger]) end)

      assert output =~ "ACTIONABLE"
      assert output =~ "#934"
      assert output =~ "Executor decision required: Should this facade target change?"
    end

    test "resolved operator decisions leave the actionable section", %{watch_root: root} do
      ledger = Path.join(root, "ledger.ndjson")
      initial_at = DateTime.utc_now() |> DateTime.to_iso8601()
      resolved_at = DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.to_iso8601()

      attention = %{
        "event" => "alert",
        "name" => "ticket.934.agent.attention.scope-question",
        "topic" => "ticket.934.agent.attention.scope-question",
        "message" => "Executor decision required",
        "reason" => "Executor decision required: Should this facade target change?",
        "severity" => "warning",
        "needs_attention" => true,
        "source_ticket_id" => "934",
        "timestamp" => initial_at
      }

      resolved = %{
        "event" => "alert",
        "name" => "ticket.934.agent.attention.scope-question.resolved",
        "topic" => "ticket.934.agent.attention.scope-question.resolved",
        "message" => "Executor decision updated",
        "reason" => "Executor decision resolved.",
        "severity" => "info",
        "needs_attention" => false,
        "source_ticket_id" => "934",
        "timestamp" => resolved_at
      }

      File.write!(ledger, Jason.encode!(attention) <> "\n" <> Jason.encode!(resolved) <> "\n")

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, ledger_paths: [ledger], blocking_asks: []) end)

      refute output =~ "ACTIONABLE"
    end

    test "CI-wait remains visible as an automatic gate, not a review-ready ticket", %{
      orchestrator: pid,
      watch_root: root
    } do
      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{
              "issue-46" => watch_entry("issue-46", "repo#46", state: "ci-wait", work_state: :paused)
            }
        }
      end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ ~r/#46\s+ci-wait/
      assert output =~ "waiting for CI"
      refute output =~ "#46 ci-wait · needs review/merge"
    end
  end
end
