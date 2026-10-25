defmodule Aiur.Orchestrator.CancellationTest do
  use Aiur.TestSupport

  alias Aiur.{Issue, Tracker, Workflow}
  alias Aiur.Orchestrator.{Calls, Cancellation, RetryEngine, State}
  alias Aiur.Orchestrator.RetryEngine.AgentDown

  @now ~U[2026-10-24 18:30:00Z]

  defmodule CancellationServer do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(request, from, state), do: Calls.handle_call(request, from, state)
  end

  test "the public API writes the tracker state, observes exit, and removes the running entry" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{id: "issue-42", identifier: "42", state: "in-progress"}
    previous_issues = Application.get_env(:aiur, :memory_tracker_issues)
    Application.put_env(:aiur, :memory_tracker_issues, [issue])

    on_exit(fn ->
      if previous_issues,
        do: Application.put_env(:aiur, :memory_tracker_issues, previous_issues),
        else: Application.delete_env(:aiur, :memory_tracker_issues)
    end)

    pid = start_test_process(fn -> ignore_stop() end)

    state = %State{
      running: %{
        issue.id =>
          issue.id
          |> running_entry(issue.identifier, pid, make_ref(), "42:attempt-api")
          |> Map.put(:headless_os_pid, 42_424)
      },
      claimed: MapSet.new([issue.id])
    }

    server = start_supervised!({CancellationServer, state})

    assert {:ok,
            %{
              issue_identifier: "42",
              tracker_state: "cancelled",
              process: %{
                handle: "42:attempt-api",
                status: "exited",
                exit_status: "killed"
              }
            }} =
             Cancellation.cancel_agent(server, "42",
               reap_fun: fn _stage -> :reaped end,
               shell_alive_fun: fn _stage -> false end,
               os_exit_timeout_ms: 0
             )

    refute Map.has_key?(:sys.get_state(server).running, issue.id)
    assert {:ok, [%Issue{state: "cancelled"}]} = Tracker.fetch_issue_states_by_ids([issue.id])
  end

  test "ambiguous bare identifiers fail before tracker or process mutation" do
    first = start_test_process(fn -> ignore_stop() end)
    second = start_test_process(fn -> ignore_stop() end)

    state = %State{
      running: %{
        "repo-a-42" => running_entry("repo-a-42", "42", first, make_ref(), "42:a"),
        "repo-b-42" => running_entry("repo-b-42", "42", second, make_ref(), "42:b")
      }
    }

    assert {:reply, {:error, :ambiguous_identifier}, ^state} =
             Cancellation.cancel_agent_call(state, "42")

    assert Process.alive?(first)
    assert Process.alive?(second)
  end

  test "an unknown ticket is distinct from a known ticket without a running agent" do
    known = %Issue{id: "issue-42", identifier: "42", state: "todo"}
    known_state = %State{last_polled_issues: %{known.id => known}}
    unknown_state = %State{}

    assert {:reply, {:error, :no_running_agent}, ^known_state} =
             Cancellation.cancel_agent_call(known_state, "42")

    assert {:reply, {:error, :issue_not_found}, ^unknown_state} =
             Cancellation.cancel_agent_call(unknown_state, "42")
  end

  test "a tracker callback never stops a replacement generation" do
    original = start_test_process(fn -> ignore_stop() end)
    replacement = start_test_process(fn -> ignore_stop() end)

    original_ref = make_ref()

    state = %State{
      running: %{
        "issue-42" => running_entry("issue-42", "42", original, original_ref, "42:original")
      }
    }

    assert {:reply, {:cancel_tracker_io, "42", stage, %Issue{}}, ^state} =
             Cancellation.cancel_agent_call(state, "42")

    replacement_state = %{
      state
      | running: %{
          "issue-42" =>
            running_entry(
              "issue-42",
              "42",
              replacement,
              make_ref(),
              "42:replacement"
            )
        }
    }

    assert {:reply, {:ok, %{process: %{handle: "42:original", status: "generation_changed"}}}, ^replacement_state} =
             Cancellation.cancel_tracker_call(replacement_state, "42", stage, :ok,
               stop_fun: fn _target -> flunk("replacement generation must not be stopped") end,
               now_fun: fn -> @now end
             )

    assert Process.alive?(replacement)
  end

  test "a delayed exit after a bounded cancellation is terminal and is not retried" do
    issue_id = "issue-42"
    ref = make_ref()
    pid = start_test_process(fn -> ignore_stop() end)

    state = %State{
      running: %{
        issue_id => running_entry(issue_id, "42", pid, ref, "42:attempt-4")
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    assert {:reply, {:cancel_tracker_io, "42", stage, %Issue{}}, ^state} =
             Cancellation.cancel_agent_call(state, "42")

    assert {:reply, {:cancel_observe, "42", ^stage, :ok}, cancelling_state} =
             Cancellation.cancel_tracker_call(state, "42", stage, :ok, stop_fun: fn _target -> :ok end)

    assert cancelling_state.running[issue_id].cancel_requested
    assert {:noreply, next} = RetryEngine.handle_agent_down(cancelling_state, ref, :killed)
    refute Map.has_key?(next.running, issue_id)
    refute Map.has_key?(next.retry_attempts, issue_id)
    refute MapSet.member?(next.claimed, issue_id)
  end

  test "a cancelled runner exit still reaps its orphaned shell" do
    issue_id = "issue-42"
    ref = make_ref()
    pid = start_test_process(fn -> ignore_stop() end)

    entry =
      issue_id
      |> running_entry("42", pid, ref, "42:attempt-reap-on-down")
      |> Map.put(:cancel_requested, true)

    state = %State{running: %{issue_id => entry}, claimed: MapSet.new([issue_id])}
    owner = self()

    assert {:noreply, next} =
             AgentDown.handle_agent_down(state, ref, :killed,
               reap_fun: fn selected ->
                 send(owner, {:orphan_reap, selected.telemetry_attempt_id})
                 :reaped
               end
             )

    assert_receive {:orphan_reap, "42:attempt-reap-on-down"}, 100
    refute Map.has_key?(next.running, issue_id)
    assert next.orphaned_agent_reap_count == 0
  end

  test "a non-exit result schedules another shell cleanup attempt" do
    pid = start_test_process(fn -> ignore_stop() end)
    state = %State{running: %{"issue-42" => running_entry("issue-42", "42", pid, make_ref(), "42:attempt-reap")}}

    assert {:reply, {:cancel_tracker_io, "42", stage, %Issue{}}, ^state} =
             Cancellation.cancel_agent_call(state, "42")

    outcome = Cancellation.result("42", stage.handle, :still_running, nil, @now)
    owner = self()

    assert {:reply, {:ok, ^outcome}, ^state} =
             Cancellation.cancel_observation_call(state, stage, outcome,
               cleanup_fun: fn selected ->
                 send(owner, {:cleanup_retried, selected.handle})
                 :ok
               end
             )

    assert_receive {:cleanup_retried, "42:attempt-reap"}, 100
  end

  test "a tracker failure leaves the selected process and running state unchanged" do
    pid = start_test_process(fn -> ignore_stop() end)
    state = %State{running: %{"issue-42" => running_entry("issue-42", "42", pid, make_ref(), "42:attempt-5")}}

    assert {:reply, {:cancel_tracker_io, "42", stage, %Issue{}}, ^state} =
             Cancellation.cancel_agent_call(state, "42")

    assert {:reply, {:error, {:tracker_cancel_failed, :write_failed}}, ^state} =
             Cancellation.cancel_tracker_call(state, "42", stage, {:error, :write_failed})

    assert Process.alive?(pid)
  end

  defp running_entry(issue_id, identifier, pid, ref, handle) do
    %{
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "in-progress"},
      pid: pid,
      ref: ref,
      telemetry_attempt_id: handle,
      started_at: @now,
      retry_attempt: 0
    }
  end

  defp ignore_stop do
    receive do
      :stop -> ignore_stop()
    end
  end

  defp start_test_process(fun), do: start_supervised!({Task, fun}, id: make_ref())
end
