defmodule Aiur.CoreTest do
  use Aiur.TestSupport

  alias Aiur.Config.Schema
  alias Aiur.Orchestrator.{Dispatcher, OperatorMessages, Reconciler, Slots}

  defmodule RetryPollFailingGitHubClient do
    def preflight_auth, do: :ok

    def fetch_candidate_issues do
      case Application.get_env(:aiur, :retry_poll_failure_test_pid) do
        pid when is_pid(pid) -> send(pid, :retry_poll_fetch_candidate_issues)
        _ -> :ok
      end

      {:error, {:github_api_status, 403}}
    end

    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issues_by_states(_states, _opts), do: {:ok, []}
  end

  defp stop_test_orchestrator(pid) when is_pid(pid) do
    if Process.alive?(pid), do: stop_live_test_orchestrator(pid)

    :ok
  end

  defp stop_live_test_orchestrator(pid) do
    stop_result =
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, reason -> {:exit, reason}
      end

    case {stop_result, Process.alive?(pid)} do
      {:ok, _} -> :ok
      {{:exit, _reason}, false} -> :ok
      {{:exit, _reason}, true} -> kill_live_test_orchestrator(pid)
    end
  end

  defp kill_live_test_orchestrator(pid) do
    ref = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> flunk("test orchestrator did not stop")
    end
  end

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_seconds: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_seconds == 30
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.linear.assignee == nil
    assert config.max_vertical_panes == 3
    assert Config.max_vertical_panes() == 3
    assert config.agent.max_turns == 20
    assert config.agent.max_concurrent_builds == 2
    assert Config.max_concurrent_builds() == 2

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_seconds: "invalid")

    assert_raise ArgumentError, ~r/interval_seconds/, fn ->
      Config.settings!().polling.interval_seconds
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_seconds"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_seconds: 45)
    assert Config.settings!().polling.interval_seconds == 45

    write_workflow_file!(Workflow.workflow_file_path(), max_vertical_panes: 4)
    assert Config.settings!().max_vertical_panes == 4
    assert Config.max_vertical_panes() == 4

    write_workflow_file!(Workflow.workflow_file_path(), max_vertical_panes: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "max_vertical_panes"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_builds: -1)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_builds"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_builds: 0)
    assert Config.max_concurrent_builds() == 0

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    # `none` means uncapped — the autonomous loop is never bounded by turns.
    write_workflow_file!(Workflow.workflow_file_path(), max_turns: "none")
    assert Config.settings!().agent.max_turns == nil

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().agent.codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "current operator .aiur/config file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()

    try do
      Workflow.set_workflow_file_path(Path.expand("../.aiur/config", File.cwd!()))

      assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
      assert is_map(config)

      tracker = Map.get(config, "tracker", %{})
      assert is_map(tracker)
      assert Map.get(tracker, "kind") in ["linear", "github", "memory"]
      assert is_list(Map.get(tracker, "active_states"))
      assert is_list(Map.get(tracker, "terminal_states"))

      hooks = Map.get(config, "hooks", %{})
      assert is_map(hooks)
      assert is_binary(Map.get(hooks, "after_create"))
      assert is_binary(Map.get(hooks, "before_remove"))
      assert String.trim(Map.get(hooks, "after_create")) != ""
      assert String.trim(Map.get(hooks, "before_remove")) != ""

      assert String.trim(prompt) != ""
      assert prompt =~ "{{ issue.identifier }}"
      assert prompt =~ "{{ issue.title }}"
      assert is_binary(Config.workflow_prompt())
      assert Config.workflow_prompt() == prompt
    after
      Workflow.set_workflow_file_path(original_workflow_path)
    end
  end

  test "checked-in workflow examples parse and portable examples stay generic" do
    workflow_paths =
      Path.wildcard("examples/workflows/*.aiurconfig") ++
        Path.wildcard("../.aiur/config")

    assert Enum.any?(workflow_paths)

    for path <- workflow_paths do
      assert {:ok, %{config: config, prompt: prompt}} = Workflow.load(path)
      assert {:ok, _settings} = Schema.parse(config)
      assert String.trim(prompt) != ""
    end

    portable_paths =
      Path.wildcard("examples/workflows/*.aiurconfig") ++
        Path.wildcard("examples/workflows/*.prompt.md")

    machine_local_pattern = ~r/(\/home\/|100\.\d+\.\d+\.\d+|applekid|orangekid|its-applekid|ethereum-optimism)/

    for path <- portable_paths do
      refute File.read!(path) =~ machine_local_pattern
    end
  end

  test "checked-in Codex GitHub workflows preserve enough turn budget and handoff context" do
    workflow_paths = [
      "examples/workflows/github-codex.aiurconfig",
      "../.aiur/config"
    ]

    for path <- workflow_paths do
      assert {:ok, %{config: config, prompt: prompt}} = Workflow.load(path)

      assert get_in(config, ["agent", "max_turns"]) >= 12
      assert prompt =~ "handoff"
      assert prompt =~ "current phase"
      assert prompt =~ "validation"
      assert prompt =~ "next steps"
    end
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.linear.api_key == env_api_key
    assert Config.settings!().tracker.linear.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.linear.assignee == env_assignee
  end

  test "workflow file path defaults to .aiur/config in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    try do
      Workflow.clear_workflow_file_path()

      assert Workflow.workflow_file_path() == Path.join([File.cwd!(), ".aiur", "config"])
    after
      Workflow.set_workflow_file_path(original_workflow_path)
    end
  end

  test "workflow file path resolves from app env when set" do
    original_workflow_path = Workflow.workflow_file_path()
    app_workflow_path = "/tmp/app/.aiurconfig"

    try do
      Workflow.set_workflow_file_path(app_workflow_path)

      assert Workflow.workflow_file_path() == app_workflow_path
    after
      Workflow.set_workflow_file_path(original_workflow_path)
    end
  end

  test "workflow load accepts a config with no prompt_file and an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "no-prompt.aiurconfig")
    File.write!(workflow_path, "tracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects a config that does not decode to a map" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "not-a-map.aiurconfig")
    File.write!(workflow_path, "- not-a-map\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "Aiur.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:aiur, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(Aiur.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(Aiur.Orchestrator)) do
        case Supervisor.restart_child(Aiur.Supervisor, Aiur.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Orchestrator)
    end

    assert {:ok, pid} = Aiur.start_link()
    assert Process.whereis(Aiur.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Reconciler.reconcile_running_issue_states([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "unexplained error issue state preserves a running agent" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-error-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-error"
    issue_identifier = "MT-ERR"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "error",
        title: "Unexpected error label",
        description: "",
        labels: []
      }

      log =
        capture_log(fn ->
          send(self(), {:updated_state, Reconciler.reconcile_running_issue_states([issue], state)})
        end)

      assert_receive {:updated_state, updated_state}

      assert Map.has_key?(updated_state.running, issue_id)
      assert MapSet.member?(updated_state.claimed, issue_id)
      assert Process.alive?(agent_pid)
      assert File.exists?(workspace)
      assert Map.fetch!(updated_state.running, issue_id).issue.state == "error"

      assert log =~ "Issue reported error state while agent is still active"
      assert log =~ "issue_id=#{issue_id}"
      assert log =~ "issue_identifier=#{issue_identifier}"
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    # Linear default config namespaces workspaces under <root>/<project_slug>/.
    workspace = Path.join([test_root, "project", issue_identifier])

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Reconciler.reconcile_running_issue_states([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_seconds: 30
      )

      Application.put_env(:aiur, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        stop_test_orchestrator(pid)
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               Aiur.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Reconciler.reconcile_running_issue_states([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Reconciler.reconcile_running_issue_states([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_test_orchestrator(pid)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    before_down_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :normal})
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, before_down_ms, 500, 1_100)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_test_orchestrator(pid)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    before_down_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, before_down_ms, 39_500, 40_500)
  end

  test "abnormal worker exit beyond max_retry_attempts gives up, clears retry state, and surfaces the error state" do
    # Drive the give-up path through the in-memory tracker so the state move is
    # observable (#708): on genuine retry exhaustion the orchestrator must push
    # the ticket into the operator-visible `error` state instead of silently
    # leaving it in `rework` with no live agent.
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "rework", "merging"],
      tracker_terminal_states: ["done", "cancelled", "canceled"]
    )

    Application.put_env(:aiur, :memory_tracker_recipient, self())

    issue_id = "issue-exhausted"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ExhaustedRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_test_orchestrator(pid)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-EX",
      # Coming back from attempt 3 means the next failure would be attempt 4,
      # which is > the default max_retry_attempts (3).
      retry_attempt: 3,
      issue: %Issue{id: issue_id, identifier: "MT-EX", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    log =
      capture_log(fn ->
        send(pid, {:DOWN, ref, :process, self(), :boom})
        # Synchronous barrier inside the capture window: `:sys.get_state/1`
        # blocks until the orchestrator has fully handled the :DOWN (and emitted
        # both its "giving up" warning and the retry_exhausted alert), so the log
        # is captured deterministically. A bare `Process.sleep/1` raced the
        # async alert emission under suite load and flaked (#589).
        :sys.get_state(pid)
      end)

    state = :sys.get_state(pid)

    refute Map.has_key?(state.retry_attempts, issue_id),
           "expected the orchestrator to give up after exceeding max_retry_attempts"

    refute MapSet.member?(state.claimed, issue_id),
           "give-up must release the claim so a label-driven re-dispatch (#699) can pick the ticket up without a daemon restart"

    assert log =~ "after 3 failed attempt(s)"
    assert log =~ "issue_id=#{issue_id}"
    assert log =~ "reason=retry_exhausted"
    assert log =~ "caller=Aiur.Orchestrator.move_exhausted_issue_to_error_state"
    assert log =~ "ticket.MT-EX.agent.retry_exhausted"

    assert_receive {:memory_tracker_state_update, "MT-EX", "error"}
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_test_orchestrator(pid)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    before_down_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, before_down_ms, 9_000, 10_500)
  end

  test "slot-starved retry preserves failure attempt and remains queued" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_concurrent_agents: 1,
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Cancelled"]
    )

    issue_id = "issue-slot-starved"
    retry_token = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :SlotStarvedRetryOrchestrator)
    issue = %Issue{id: issue_id, identifier: "MT-SLOT", title: "Retry me", state: "In Progress"}

    Application.put_env(:aiur, :memory_tracker_issues, [issue])
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    initial_state = :sys.get_state(pid)

    busy_worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    on_exit(fn ->
      send(busy_worker_pid, :done)
      stop_test_orchestrator(pid)
    end)

    other_running_entry = %{
      pid: busy_worker_pid,
      ref: make_ref(),
      identifier: "MT-BUSY",
      issue: %Issue{id: "issue-busy", identifier: "MT-BUSY", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{"issue-busy" => other_running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 1,
          retry_token: retry_token,
          timer_ref: nil,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: "MT-SLOT",
          error: "agent exited: :response_timeout"
        }
      })
    end)

    before_retry_ms = System.monotonic_time(:millisecond)
    send(pid, {:retry_issue, issue_id, retry_token})
    state = :sys.get_state(pid)
    observed_at_ms = System.monotonic_time(:millisecond)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             identifier: "MT-SLOT",
             error: "no available orchestrator slots"
           } = state.retry_attempts[issue_id]

    assert is_reference(state.retry_attempts[issue_id].retry_token)
    assert_due_in_range(due_at_ms, before_retry_ms, 1_000, observed_at_ms - before_retry_ms + 1_000)

    busy_state = %{state | running: %{"issue-busy" => other_running_entry}}
    freed_state = %{state | running: %{}}
    refute Dispatcher.retry_dispatch_ready?(issue, busy_state, nil)
    assert Dispatcher.retry_dispatch_ready?(issue, freed_state, nil)
  end

  test "retry poll failures do not consume agent retry budget" do
    issue_id = "issue-retry-poll-fail"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :RetryPollFailureOrchestrator)
    previous_github_client = Application.get_env(:aiur, :github_client_module)
    previous_test_pid = Application.get_env(:aiur, :retry_poll_failure_test_pid)
    previous_github_token = System.get_env("GITHUB_TOKEN")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "its-everdred/aiur",
      tracker_active_states: ["todo", "in-progress"],
      tracker_terminal_states: ["done"],
      max_retry_backoff_ms: 100
    )

    Application.put_env(:aiur, :github_client_module, RetryPollFailingGitHubClient)
    Application.put_env(:aiur, :retry_poll_failure_test_pid, self())
    System.put_env("GITHUB_TOKEN", "retry-poll-test-token")

    on_exit(fn ->
      if previous_github_client do
        Application.put_env(:aiur, :github_client_module, previous_github_client)
      else
        Application.delete_env(:aiur, :github_client_module)
      end

      if previous_test_pid do
        Application.put_env(:aiur, :retry_poll_failure_test_pid, previous_test_pid)
      else
        Application.delete_env(:aiur, :retry_poll_failure_test_pid)
      end

      restore_env("GITHUB_TOKEN", previous_github_token)
    end)

    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_test_orchestrator(pid)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-POLL",
      issue: %Issue{id: issue_id, identifier: "MT-POLL", state: "in-progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :response_timeout})
    Process.sleep(50)

    assert %{attempt: 1, retry_token: retry_token, error: "agent exited: :response_timeout"} =
             :sys.get_state(pid).retry_attempts[issue_id]

    log =
      capture_log(fn ->
        send(pid, {:retry_issue, issue_id, retry_token})
        Process.sleep(50)

        assert %{attempt: 1, retry_poll_failures: 1, retry_token: retry_token} =
                 :sys.get_state(pid).retry_attempts[issue_id]

        send(pid, {:retry_issue, issue_id, retry_token})
        Process.sleep(50)

        assert %{attempt: 1, retry_poll_failures: 2, retry_token: retry_token} =
                 :sys.get_state(pid).retry_attempts[issue_id]

        send(pid, {:retry_issue, issue_id, retry_token})
        # Barrier: blocks until the third retry (exhaustion path) is fully
        # handled, so the synchronous `[alert]` log line is emitted before
        # capture_log flushes — deterministic vs. a fixed sleep.
        _ = :sys.get_state(pid)
      end)

    state = :sys.get_state(pid)

    refute Map.has_key?(state.retry_attempts, issue_id),
           "retry-poll exhaustion should clear the precondition retry entry"

    refute MapSet.member?(state.claimed, issue_id),
           "retry-poll exhaustion should release the claim for tracker-recovery pickup"

    assert log =~ "Retry poll failed for issue_id=#{issue_id} issue_identifier=MT-POLL"
    assert log =~ "retry_poll_failure=2/3 agent_attempt=1 tracker_error={:github_api_status, 403}"
    assert log =~ "Retrying retry-poll precondition issue_id=#{issue_id} issue_identifier=MT-POLL"
    assert log =~ "Retry poll exhausted for issue_id=#{issue_id} issue_identifier=MT-POLL agent_attempt=1"
    assert log =~ "[alert] (#MT-POLL) orchestrator.retry_poll.exhausted"
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_test_orchestrator(pid)
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host/2 skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Slots.select_worker_host(state, nil) == "worker-b"
  end

  test "select_worker_host/2 returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Slots.select_worker_host(state, nil) == :no_worker_capacity
  end

  test "select_worker_host/2 keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Slots.select_worker_host(state, "worker-a") == "worker-a"
  end

  defp assert_due_in_range(due_at_ms, scheduled_after_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert due_at_ms >= scheduled_after_ms + min_remaining_ms
    assert remaining_ms <= max_remaining_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes invalid rendered bytes to utf8" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.title }}")

    issue = %Issue{
      identifier: "MT-698",
      title: <<255>>,
      description: "Prompt should not return invalid bytes",
      state: "Todo",
      url: "https://example.org/issues/MT-698",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert String.valid?(prompt)
    refute prompt == <<"Ticket ", 255>>
  end

  test "prompt builder prepends shared agent instructions" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-699",
      title: "Use shared prompt instructions",
      description: "Prompt should include repo-wide guidance",
      state: "Todo",
      url: "https://example.org/issues/MT-699",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    # The shared prefix is slimmed to the always-visible / between-turn
    # reflexes plus a pointer to the `using-aiur` operating-manual skill.
    assert prompt =~ "## Shared Agent Instructions"
    assert prompt =~ "using-aiur"
    assert prompt =~ "Progress emits"
    assert prompt =~ "Executor check-ins"

    # The general operating manual (complexity routing, CODEOWNERS authority,
    # PR shape, milestone-alert names, the dev loop) now lives only in the
    # `using-aiur` skill — it is no longer inlined into every per-turn prompt.
    refute prompt =~ "### Complexity routing"
    refute prompt =~ "#### `complexity:"
    refute prompt =~ "label-based complexity is the default"
    refute prompt =~ "### PR description shape"
    refute prompt =~ "### Whose comments to act on"
    refute prompt =~ "use CODEOWNERS as the authority signal"
    refute prompt =~ "brainstorm.start"

    assert prompt =~ "Ticket MT-699"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    # `PromptBuilder` prepends shared-agent-instructions; assert on
    # the rendered tail rather than equality.
    assert String.ends_with?(PromptBuilder.build_prompt(issue), "Ticket MT-701")
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(Aiur.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid), do: ensure_workflow_store_running()
    end)

    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo operator .aiur/config renders correctly" do
    workflow_path = Workflow.workflow_file_path()

    Workflow.set_workflow_file_path(Path.expand("../.aiur/config", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for the prompt",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "MT-616"
    assert prompt =~ "Use rich templates for the prompt"
    assert prompt =~ "In Progress"
    assert prompt =~ "Render with rich template variables"
    assert prompt =~ "templating"
    assert prompt =~ "workflow"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "Continuation context:"
    assert prompt =~ ~r/[Rr]etry attempt #2/
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    # `PromptBuilder` prepends a shared-agent-instructions block when
    # the file is present at `prompts/shared-agent-instructions.md`,
    # so we assert on the rendered tail rather than equality.
    assert String.ends_with?(prompt, "Retry #2")
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      # Linear default config namespaces workspaces under <root>/<project_slug>/,
      # so the issue dir lands in workspace_root/project/, not directly under root.
      repo_dir = Path.join(workspace_root, "project")
      before = if File.dir?(repo_dir), do: MapSet.new(File.ls!(repo_dir)), else: MapSet.new()
      assert :ok = AgentRunner.run(issue)

      created = MapSet.difference(MapSet.new(File.ls!(repo_dir)), before)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(repo_dir, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"

      workspace = Path.join([workspace_root, "project", "MT-99"])
      ndjson_log = Path.join(workspace, "logs/agent.ndjson")
      markdown_log = Path.join(workspace, "logs/agent.md")

      assert File.exists?(ndjson_log)
      assert File.exists?(markdown_log)

      assert File.read!(ndjson_log) =~ "\"event\":\"session_started\""
      assert File.read!(ndjson_log) =~ "\"event\":\"turn_completed\""
      assert File.read!(markdown_log) =~ "session_started"
      assert File.read!(markdown_log) =~ "turn_completed"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/aiur-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__AIUR_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__AIUR_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__AIUR_WORKSPACE__' '1' '/remote/home/.aiur-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.aiur-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner pauses on before_run failure and resumes after operator intervention" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-agent-runner-before-run-pause-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      before_run_trace = Path.join(test_root, "before-run.trace")
      codex_trace = Path.join(test_root, "codex.trace")
      resume_marker = Path.join(test_root, "allow-before-run")
      identifier = "MT-BEFORE-RUN-PAUSE-#{System.unique_integer([:positive])}"

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file=#{inspect(codex_trace)}
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        request_id=$(printf '%s' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p')
        case "$line" in
          *'"method":"initialize"'*)
            printf '{"id":%s,"result":{}}\\n' "$request_id"
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '{"id":%s,"result":{"thread":{"id":"thread-before-run-resume"}}}\\n' "$request_id"
            ;;
          *'"method":"turn/start"'*)
            printf '{"id":%s,"result":{"turn":{"id":"turn-before-run-resume"}}}\\n' "$request_id"
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        hook_before_run: """
        printf 'before_run\\n' >> #{before_run_trace}
        if [ ! -f #{resume_marker} ]; then
          printf '%s\\n' 'dependency fetch failed' >&2
          exit 74
        fi
        """,
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      issue = %Issue{
        id: "issue-before-run-pause",
        identifier: identifier,
        title: "Pause on hook failure",
        description: "before_run should pause instead of exhausting retries",
        state: "In Progress",
        url: "https://example.org/issues/MT-BEFORE-RUN-PAUSE",
        labels: []
      }

      test_pid = self()

      task =
        Task.async(fn ->
          AgentRunner.run(
            issue,
            test_pid,
            issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
          )
        end)

      assert_receive {:worker_control_state, "issue-before-run-pause", :paused, %{kind: :before_run_failure}},
                     5_000

      refute_receive {:codex_worker_update, "issue-before-run-pause", %{event: :session_started}}, 200
      assert Task.yield(task, 50) == nil

      File.write!(resume_marker, "ok\n")
      send(task.pid, {:resume_agent, 101})

      assert_receive {:worker_control_state, "issue-before-run-pause", :working}, 5_000

      receive do
        {:codex_worker_update, "issue-before-run-pause", %{event: :session_started}} -> :ok
      after
        5_000 ->
          flunk("session did not start after resume; codex trace:\n#{File.read!(codex_trace)}")
      end

      assert {:ok, :ok} = Task.yield(task, 15_000)

      assert before_run_trace |> File.read!() |> String.split("\n", trim: true) |> length() == 2
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      turn_count=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          *'"method":"turn/start"'*)
            turn_count=$((turn_count + 1))
            printf '{"id":3,"result":{"turn":{"id":"turn-cont-%s"}}}\\n' "$turn_count"
            printf '{"method":"turn/completed","params":{"turn":{"id":"turn-cont-%s","status":"completed"}}}\\n' "$turn_count"
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
      assert Enum.at(turn_texts, 1) =~ "If manual `scripts/aiurdev --test`"
      assert Enum.at(turn_texts, 1) =~ "do not retry from `/tmp`"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner drains queued operator messages at the turn boundary" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-agent-runner-queued-operator-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-queue"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-queue-1"}}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-queue-1","status":"completed"}}}'
            ;;
          *)
            if printf '%s' "$line" | grep -q '"method":"turn/start"'; then
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-queue-2"}}}'
              printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-queue-2","status":"completed"}}}'
            fi
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEX_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      orchestrator_name = Module.concat(__MODULE__, :QueuedOperatorOrchestrator)
      {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
      end)

      :sys.replace_state(orchestrator_pid, fn state ->
        {queue_store, _item} =
          Aiur.AgentQueue.operator_message("MT-249", "focus on auth first")
          |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

        %{state | queue_store: queue_store}
      end)

      issue = %Issue{
        id: "issue-queue",
        identifier: "MT-249",
        title: "Drain queued operator message",
        description: "Deliver follow-up after the first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-249",
        labels: []
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 orchestrator: orchestrator_name,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      turn_texts =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) == "focus on auth first"
      assert :empty == OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-249")
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "completed Codex runner replacement drains queued rework once" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-completed-codex-replacement-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      rework_started = Path.join(test_root, "rework.started")
      rework_release = Path.join(test_root, "rework.release")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="$SYMP_TEST_CODEX_TRACE"
      turn_start_count=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-replacement"}}}'
            ;;
          *'"method":"turn/start"'*)
            turn_start_count=$((turn_start_count + 1))
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')

            case "$turn_start_count" in
              1)
                printf '{"id":%s,"result":{"turn":{"id":"turn-replacement-main","status":"inProgress"}}}\\n' "$request_id"
                printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-replacement-main","status":"completed"}}}'
                ;;
              2)
                printf '{"id":%s,"result":{"turn":{"id":"turn-replacement-rework","status":"inProgress"}}}\\n' "$request_id"
                touch "#{rework_started}"
                while [ ! -f "#{rework_release}" ]; do sleep 0.01; done
                printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-replacement-rework","status":"completed"}}}'
                ;;
            esac
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      issue = %Issue{
        id: "issue-completed-codex-replacement",
        identifier: "MT-CODEX-REPLACEMENT",
        title: "Drain rework on replacement",
        description: "The completed Codex worker must be replaceable",
        state: "rework",
        url: "https://example.org/issues/MT-CODEX-REPLACEMENT",
        labels: [],
        selected_backend: "codex"
      }

      Application.put_env(:aiur, :memory_tracker_issues, [issue])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["in-progress", "rework"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      orchestrator_name = Module.concat(__MODULE__, :CompletedCodexReplacementOrchestrator)
      {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)
      {:ok, old_worker} = Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> Process.sleep(:infinity) end)
      old_ref = Process.monitor(old_worker)

      on_exit(fn ->
        File.touch(rework_release)
        System.delete_env("SYMP_TEST_CODEX_TRACE")
        if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
        if Process.alive?(old_worker), do: Process.exit(old_worker, :kill)
      end)

      :sys.replace_state(orchestrator_pid, fn state ->
        if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

        old_entry = %{
          pid: old_worker,
          ref: old_ref,
          identifier: issue.identifier,
          issue: issue,
          worker_host: nil,
          workspace_path: nil,
          session_id: "old-generation",
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_app_server_pid: nil,
          codex_process_group_id: nil,
          repl_pane_id: nil,
          repl_os_pid: nil,
          headless_os_pid: nil,
          agent_input_tokens: 0,
          agent_output_tokens: 0,
          agent_total_tokens: 0,
          agent_last_reported_input_tokens: 0,
          agent_last_reported_output_tokens: 0,
          agent_last_reported_total_tokens: 0,
          turn_count: 1,
          control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :working},
          retry_attempt: 0,
          started_at: DateTime.utc_now()
        }

        %{
          state
          | session_max_concurrent_agents: 1,
            running: %{issue.id => old_entry},
            claimed: MapSet.put(state.claimed, issue.id),
            tick_timer_ref: nil,
            tick_token: make_ref(),
            next_poll_due_at_ms: nil,
            poll_check_in_progress: false
        }
      end)

      send(orchestrator_pid, {:worker_control_state, issue.id, :completed})

      assert %{active: 0} = Orchestrator.max_concurrent_agents(orchestrator_name)

      assert {:ok, item_id} =
               Orchestrator.send_operator_message(orchestrator_name, issue.identifier, %{
                 kind: :text,
                 body: "repair from replacement"
               })

      refute Process.alive?(old_worker)

      replacement = :sys.get_state(orchestrator_pid).running[issue.id]
      assert is_pid(replacement.pid)
      assert Process.alive?(replacement.pid)
      assert replacement.pid != old_worker
      assert is_reference(replacement.ref)
      assert replacement.ref != old_ref
      replacement_pid = replacement.pid
      completion_ref = Process.monitor(replacement_pid)

      assert wait_for_path(rework_started, 15_000)

      in_flight = :sys.get_state(orchestrator_pid)
      assert in_flight.running[issue.id].pid == replacement.pid
      assert in_flight.queue_store.items[item_id].status == :delivered
      assert in_flight.queue_store.items[item_id].delivery_attempts == 1

      send(orchestrator_pid, {:DOWN, old_ref, :process, old_worker, :normal})
      assert :sys.get_state(orchestrator_pid).running[issue.id].pid == replacement.pid

      File.touch!(rework_release)

      assert_receive {:DOWN, ^completion_ref, :process, ^replacement_pid, :normal},
                     15_000

      finished = :sys.get_state(orchestrator_pid)
      assert finished.queue_store.items[item_id].status == :consumed
      assert finished.queue_store.items[item_id].delivery_attempts == 1
      assert Map.get(finished.queue_store.pending_ids_by_target, issue.identifier, []) == []

      turn_texts =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) == "repair from replacement"
    after
      File.touch(Path.join(test_root, "rework.release"))
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner drains an interrupting operator message after interrupted completion" do
    assert_agent_runner_interrupt_operator(:interrupted_completion)
  end

  test "agent runner drains an interrupting operator message after response-only no-active-turn" do
    assert_agent_runner_interrupt_operator(:no_active_turn)
  end

  defp assert_agent_runner_interrupt_operator(interrupt_outcome) do
    outcome_name = Atom.to_string(interrupt_outcome)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-agent-runner-interrupt-operator-#{outcome_name}-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex.trace}"
      first_turn_started=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-interrupt-operator"}}}'
            ;;
          *'"method":"turn/start"'*)
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')

            if [ "$first_turn_started" -eq 0 ]; then
              first_turn_started=1
              printf '{"id":%s,"result":{"turn":{"id":"turn-main"}}}\\n' "$request_id"
            else
              printf '{"id":%s,"result":{"turn":{"id":"turn-operator"}}}\\n' "$request_id"
              printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
              exit 0
            fi
            ;;
          *'"method":"turn/interrupt"'*)
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      #{operator_interrupt_frames(interrupt_outcome)}
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEX_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      orchestrator_name =
        Module.concat(
          __MODULE__,
          "InterruptOperator#{Macro.camelize(outcome_name)}Orchestrator"
        )

      {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
      end)

      issue_id = "issue-interrupt-operator-#{outcome_name}"
      identifier = "MT-INTERRUPT-OPERATOR-#{String.upcase(outcome_name)}"

      issue = %Issue{
        id: issue_id,
        identifier: identifier,
        title: "Interrupt with operator message",
        description: "Stop the active turn and deliver the operator input next",
        state: "In Progress",
        url: "https://example.org/issues/MT-253",
        labels: []
      }

      test_pid = self()

      task =
        Task.async(fn ->
          AgentRunner.run(
            issue,
            test_pid,
            orchestrator: orchestrator_name,
            issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
          )
        end)

      assert_receive {:codex_worker_update, ^issue_id, %{event: :session_started}}, 5_000

      :sys.replace_state(orchestrator_pid, fn state ->
        {queue_store, item} =
          Aiur.AgentQueue.operator_message(identifier, "stop and answer this", delivery_policy: :interrupt)
          |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

        send(test_pid, {:queued_request_id, item.id})
        %{state | queue_store: queue_store}
      end)

      assert_receive {:queued_request_id, request_id}
      send(task.pid, {:agent_queue_updated, identifier, request_id, true})

      assert {:ok, :ok} = Task.yield(task, 15_000)

      trace =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)

      assert Enum.any?(trace, &String.contains?(&1, ~s("method":"turn/interrupt")))

      turn_texts =
        trace
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) == "stop and answer this"
      assert :empty == OperatorMessages.claim_next_queue_item(orchestrator_name, identifier)
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  defp operator_interrupt_frames(:interrupted_completion) do
    """
            printf '{"id":%s,"result":{}}\\n' "$request_id"
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"interrupted"}}}'
    """
  end

  defp operator_interrupt_frames(:no_active_turn) do
    """
            printf '{"id":%s,"error":{"code":-32600,"message":"no active turn"}}\\n' "$request_id"
    """
  end

  test "agent runner delivers queued operator messages from a sub-turn checkpoint" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-agent-runner-checkpoint-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex.trace}"
      count=0
      first_turn_started=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-checkpoint"}}}'
            ;;
          *'"method":"turn/start"'*)
            if [ "$first_turn_started" -eq 0 ]; then
              first_turn_started=1
              request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
              printf '{"id":%s,"result":{"turn":{"id":"turn-checkpoint-main"}}}\\n' "$request_id"
              printf '%s\\n' '{"method":"turn/plan/updated","params":{"plan":[{"step":"keep going"}]}}'
            else
              request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
              printf '{"id":%s,"result":{"turn":{"id":"turn-accepted-steering","status":"inProgress"}}}\\n' "$request_id"
              printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-checkpoint-main","status":"completed"}}}'
              exit 0
            fi
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEX_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      orchestrator_name = Module.concat(__MODULE__, :CheckpointOperatorOrchestrator)
      {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
      end)

      :sys.replace_state(orchestrator_pid, fn state ->
        {queue_store, _item} =
          Aiur.AgentQueue.operator_message("MT-250", "focus on auth first")
          |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

        %{state | queue_store: queue_store}
      end)

      issue = %Issue{
        id: "issue-checkpoint-queue",
        identifier: "MT-250",
        title: "Deliver queued operator message from checkpoint",
        description: "Deliver follow-up before the original turn returns",
        state: "In Progress",
        url: "https://example.org/issues/MT-250",
        labels: []
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 orchestrator: orchestrator_name,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      turn_texts =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) == "focus on auth first"
      assert :empty == OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-250")
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner requeues drained operator message when parent turn completes before delivery acknowledgement" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-agent-runner-checkpoint-completion-race-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex.trace}"
      turn_start_count=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-completion-race"}}}'
            ;;
          *'"method":"turn/start"'*)
            turn_start_count=$((turn_start_count + 1))
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')

            case "$turn_start_count" in
              1)
                printf '{"id":%s,"result":{"turn":{"id":"turn-main"}}}\\n' "$request_id"
                printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
                ;;
              2)
                # Simulate the completion-boundary race: the app-server accepts
                # bytes for the drained follow-up but never acknowledges this
                # turn/start request after the parent turn completed.
                ;;
            esac
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEX_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      orchestrator_name = Module.concat(__MODULE__, :CheckpointCompletionRaceOrchestrator)
      {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
      end)

      :sys.replace_state(orchestrator_pid, fn state ->
        {queue_store, _item} =
          Aiur.AgentQueue.operator_message("MT-254", "finish with this guardrail")
          |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

        %{state | queue_store: queue_store}
      end)

      issue = %Issue{
        id: "issue-checkpoint-completion-race",
        identifier: "MT-254",
        title: "Requeue operator input after completion race",
        description: "Do not fail completed parent turn when checkpoint follow-up loses race",
        state: "In Progress",
        url: "https://example.org/issues/MT-254",
        labels: []
      }

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert :ok =
                   AgentRunner.run(
                     issue,
                     nil,
                     orchestrator: orchestrator_name,
                     issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
                   )
        end)

      turn_texts =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) == "finish with this guardrail"

      assert {:ok, %{category: :operator_message, body: %{text: "finish with this guardrail"}}} =
               OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-254")

      assert :sys.get_state(orchestrator_pid).retry_attempts == %{}
      assert log =~ "Queued item delivery lost completion race"
      assert log =~ "issue_id=issue-checkpoint-completion-race"
      assert log =~ "request_id="
      assert log =~ "reason=:response_timeout"
      assert log =~ "decision=requeue_after_parent_turn_completed"
      refute log =~ "Agent run failed"
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner interrupts an active turn and waits for the next operator message before resuming" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-agent-runner-pause-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex.trace}"
      first_turn_started=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-pause"}}}'
            ;;
          *'"method":"turn/start"'*)
            if [ "$first_turn_started" -eq 0 ]; then
              first_turn_started=1
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-main"}}}'
            else
              request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
              printf '{"id":%s,"result":{"turn":{"id":"turn-resume"}}}\\n' "$request_id"
              printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
              exit 0
            fi
            ;;
          *'"method":"turn/interrupt"'*)
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
            printf '{"id":%s,"result":{}}\\n' "$request_id"
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"interrupted"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEX_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      orchestrator_name = Module.concat(__MODULE__, :PauseResumeOrchestrator)
      {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
      end)

      issue = %Issue{
        id: "issue-pause-resume",
        identifier: "MT-251",
        title: "Pause and resume",
        description: "interrupt active work and wait for operator input",
        state: "In Progress",
        url: "https://example.org/issues/MT-251",
        labels: []
      }

      test_pid = self()

      task =
        Task.async(fn ->
          AgentRunner.run(
            issue,
            test_pid,
            orchestrator: orchestrator_name,
            issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
          )
        end)

      assert_receive {:codex_worker_update, "issue-pause-resume", %{event: :session_started}}, 5_000

      send(task.pid, {:pause_agent, 91})

      assert_receive {:worker_control_state, "issue-pause-resume", :paused, %{request_id: 91, turn_id: "turn-main"}},
                     5_000

      :sys.replace_state(orchestrator_pid, fn state ->
        {queue_store, item} =
          Aiur.AgentQueue.operator_message("MT-251", "resume with the auth fix")
          |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

        send(test_pid, {:queued_request_id, item.id})
        %{state | queue_store: queue_store}
      end)

      assert_receive {:queued_request_id, request_id}

      send(task.pid, {:agent_queue_updated, "MT-251", request_id})

      assert {:ok, :ok} = Task.yield(task, 15_000)

      trace =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)

      assert Enum.any?(trace, &String.contains?(&1, ~s("method":"turn/interrupt")))

      turn_texts =
        trace
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) == "resume with the auth fix"

      workspace_log =
        Path.join([workspace_root, "project", "MT-251", "logs", "agent.md"])
        |> File.read!()

      assert workspace_log =~ "worker_paused"
      assert workspace_log =~ "Agent paused by Executor."
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner remains paused when idle precedes a no-active-turn interrupt response" do
    assert_agent_runner_pause_no_active_turn(:idle_first)
  end

  test "agent runner remains paused when a no-active-turn interrupt response precedes idle" do
    assert_agent_runner_pause_no_active_turn(:response_first)
  end

  test "agent runner remains paused when no idle follows a no-active-turn interrupt response" do
    assert_agent_runner_pause_no_active_turn(:response_only)
  end

  defp assert_agent_runner_pause_no_active_turn(event_order) do
    order_name = Atom.to_string(event_order)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-agent-runner-pause-no-active-turn-#{order_name}-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex.trace}"

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-pause-no-active"}}}'
            ;;
          *'"method":"turn/start"'*)
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
            printf '{"id":%s,"result":{"turn":{"id":"turn-main"}}}\\n' "$request_id"
            printf '%s\\n' '{"method":"turn/started","params":{"turn":{"id":"turn-main","status":"inProgress"}}}'
            ;;
          *'"method":"turn/interrupt"'*)
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      #{no_active_turn_interrupt_frames(event_order)}
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEX_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      orchestrator_name =
        Module.concat(
          __MODULE__,
          "PauseNoActiveTurn#{Macro.camelize(order_name)}Orchestrator"
        )

      {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
      end)

      issue_id = "issue-pause-no-active-turn-#{order_name}"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-PAUSE-NO-ACTIVE-#{String.upcase(order_name)}",
        title: "Preserve pause at a completed turn boundary",
        description: "do not continue after Codex reports no active turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-PAUSE-NO-ACTIVE",
        labels: []
      }

      test_pid = self()

      task =
        Task.async(fn ->
          AgentRunner.run(
            issue,
            test_pid,
            orchestrator: orchestrator_name,
            issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
          )
        end)

      assert_receive {:codex_worker_update, ^issue_id,
                      %{
                        event: :notification,
                        payload: %{"method" => "turn/started"}
                      }},
                     15_000

      send(task.pid, {:pause_agent, 93})

      assert_receive {:worker_control_state, ^issue_id, :paused, %{request_id: 93, turn_id: "turn-main"}},
                     5_000

      refute Task.yield(task, 100)

      trace = File.read!(trace_file)
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 1

      send(task.pid, {:resume_agent, 94})
      assert {:ok, :ok} = Task.yield(task, 5_000)

      trace = File.read!(trace_file)
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 1
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  defp no_active_turn_interrupt_frames(:idle_first) do
    """
            printf '%s\\n' '{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}'
            printf '{"id":%s,"error":{"code":-32600,"message":"no active turn"}}\\n' "$request_id"
    """
  end

  defp no_active_turn_interrupt_frames(:response_first) do
    """
            printf '{"id":%s,"error":{"code":-32600,"message":"no active turn"}}\\n' "$request_id"
            printf '%s\\n' '{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}'
    """
  end

  defp no_active_turn_interrupt_frames(:response_only) do
    """
            printf '{"id":%s,"error":{"code":-32600,"message":"no active turn"}}\\n' "$request_id"
    """
  end

  test "agent runner processes restored and newly-queued operator input on explicit resume after pause" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-agent-runner-requeue-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex.trace}"
      turn_start_count=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-requeue"}}}'
            ;;
          *'"method":"turn/start"'*)
            turn_start_count=$((turn_start_count + 1))
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')

            case "$turn_start_count" in
              1)
                printf '{"id":%s,"result":{"turn":{"id":"turn-main"}}}\\n' "$request_id"
                printf '%s\\n' '{"method":"turn/plan/updated","params":{"plan":[{"step":"checkpoint"}]}}'
                ;;
              2)
                printf '{"id":%s,"result":{"turn":{"id":"turn-checkpoint-abc"}}}\\n' "$request_id"
                ;;
              3)
                printf '{"id":%s,"result":{"turn":{"id":"turn-resume-abc"}}}\\n' "$request_id"
                printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
                ;;
              4)
                printf '{"id":%s,"result":{"turn":{"id":"turn-def"}}}\\n' "$request_id"
                printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-def","status":"completed"}}}'
                exit 0
                ;;
            esac
            ;;
          *'"method":"turn/interrupt"'*)
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
            printf '{"id":%s,"result":{}}\\n' "$request_id"
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"interrupted"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEX_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      orchestrator_name = Module.concat(__MODULE__, :CheckpointRequeueOrchestrator)
      {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
      end)

      :sys.replace_state(orchestrator_pid, fn state ->
        {queue_store, _item} =
          Aiur.AgentQueue.operator_message("MT-252", "abc")
          |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

        %{state | queue_store: queue_store}
      end)

      issue = %Issue{
        id: "issue-checkpoint-requeue",
        identifier: "MT-252",
        title: "Preserve queued input across pause",
        description: "requeue checkpoint-delivered input when pause interrupts the active turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-252",
        labels: []
      }

      test_pid = self()

      task =
        Task.async(fn ->
          AgentRunner.run(
            issue,
            test_pid,
            orchestrator: orchestrator_name,
            issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
          )
        end)

      assert_receive {:codex_worker_update, "issue-checkpoint-requeue", %{event: :session_started}}, 5_000
      Process.sleep(50)

      send(task.pid, {:pause_agent, 92})

      :sys.replace_state(orchestrator_pid, fn state ->
        {queue_store, item} =
          Aiur.AgentQueue.operator_message("MT-252", "def")
          |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

        send(test_pid, {:queued_request_id, item.id})
        %{state | queue_store: queue_store}
      end)

      assert_receive {:queued_request_id, _request_id}
      # The paused worker no longer eagerly claims restored items on its
      # own — that was the bug behind the pause→auto-unpause loop reported
      # in issue #15. Explicit resume drains the operator queue so both
      # the restored "abc" and the newly-enqueued "def" land as turns.
      send(task.pid, {:resume_agent, 99})

      assert {:ok, :ok} = Task.yield(task, 15_000)

      turn_texts =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 4
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) == "abc"
      assert Enum.at(turn_texts, 2) == "abc"
      assert Enum.at(turn_texts, 3) == "def"
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      after_run_started = Path.join(test_root, "after-run.started")
      after_run_release = Path.join(test_root, "after-run.release")
      after_run_done = Path.join(test_root, "after-run.done")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-max-2","status":"completed"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        hook_after_run: "touch #{after_run_started}; while [ ! -f #{after_run_release} ]; do sleep 0.01; done; touch #{after_run_done}",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      test_pid = self()

      task =
        Task.async(fn ->
          AgentRunner.run(issue, test_pid, issue_state_fetcher: state_fetcher)
        end)

      assert wait_for_path(after_run_started, 15_000)
      refute_receive {:worker_control_state, "issue-max-turns", :completed}, 100

      File.touch!(after_run_release)

      assert_receive {:worker_control_state, "issue-max-turns", :completed}, 2_000
      assert File.exists?(after_run_done)
      assert :ok = Task.await(task, 2_000)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  defp wait_for_path(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_path(path, deadline)
  end

  defp do_wait_for_path(path, deadline) do
    cond do
      File.exists?(path) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        do_wait_for_path(path, deadline)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = Aiur.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = "untrusted"

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => true,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = "untrusted"

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --config 'model=\"gpt-5.5\"' app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--config model=\"gpt-5.5\" app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)
      assert {:ok, canonical_workspace} = Aiur.PathSafety.canonicalize(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_writable_roots =
        [Path.expand(workspace), workspace_cache]
        |> then(fn roots -> if canonical_workspace in roots, do: roots, else: roots ++ [canonical_workspace] end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => expected_writable_roots
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end
end
