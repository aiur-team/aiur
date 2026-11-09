defmodule Aiur.TestSupport.RunnerTasksTest do
  # #5104: a dispatched runner task outlived its test and kept writing the
  # repo state tree into a later test's `:repo_base_root` during its cleanup.
  use Aiur.TestSupport

  alias Aiur.{Issue, RepoBase, Workflow}
  alias Aiur.Orchestrator.{Dispatcher, State}
  alias Aiur.TestSupport.RunnerTasks

  @repo_url "https://github.com/test-org/test-repo"

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "rework"]
    )

    :ok
  end

  test "stops a dispatched runner that would write into a later test's repo root" do
    issue = %Issue{
      id: "5104",
      identifier: "5104",
      title: "leaked runner",
      state: "todo",
      state_labels: ["todo"],
      selected_backend: "codex",
      labels: ["agent:todo"]
    }

    Application.put_env(:aiur, :memory_tracker_issues, [issue])
    parent = self()
    before = RunnerTasks.capture()

    state =
      Dispatcher.dispatch_issue(%State{max_concurrent_agents: 4, effective_concurrent_agents: 4}, issue, nil, nil,
        blocked_by_hydrator: &{:ok, &1},
        runner: fn _issue, _recipient, _opts ->
          send(parent, {:runner_started, self()})
          write_on_request()
        end
      )

    assert Map.has_key?(state.running, issue.id)
    assert_receive {:runner_started, runner}, 5000

    # A later test rebinds the root; the live runner writes into it, as
    # `Workspace.Hooks.hook_env/2` does.
    later_root = Aiur.TestSupport.tmp_root!("runner-tasks-later-root")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(later_root, unset: [:repo_base_root]) end)
    Application.put_env(:aiur, :repo_base_root, later_root)
    node = RepoBase.repo_path(@repo_url)
    send(runner, {:write, self()})
    assert_receive {:written, ^runner}, 5000
    assert File.dir?(node)

    assert :ok = RunnerTasks.stop_started_since(before)
    refute Process.alive?(runner)

    Aiur.TestCleanup.rm_rf!(later_root, unset: [:repo_base_root])
    send(runner, {:write, self()})
    refute_receive {:written, ^runner}, 100
    refute File.exists?(node)
  end

  # #5581: a :rest_for_one restart shut Aiur.TaskSupervisor down between the
  # name lookup and the children call, so the shared teardown raised and leaked
  # its state into the next test. Use a private supervisor so this race does
  # not unregister the app-wide task supervisor while other tests are running.
  test "a task supervisor that exits while asked has no runner tasks left" do
    stand_in = start_supervised!({Task.Supervisor, name: nil})

    :ok = :sys.suspend(stand_in)
    capture = Task.async(fn -> RunnerTasks.capture(stand_in) end)
    Aiur.DispatcherTestSupport.wait_until(fn -> Process.info(stand_in, :message_queue_len) == {:message_queue_len, 1} end)
    Process.exit(stand_in, :kill)

    assert Task.await(capture) == MapSet.new()
  end

  defp write_on_request do
    receive do
      {:write, caller} ->
        :ok = RepoBase.ensure_state_tree(@repo_url)
        send(caller, {:written, self()})
        write_on_request()
    end
  end
end
