defmodule Aiur.GitHub.Listeners.PollFailureTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Listeners.Firehose
  alias Aiur.Orchestrator.{FirehosePolling, State, TrackerTasks}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    listener = start_supervised!(Supervisor.child_spec({Firehose, []}, restart: :temporary))

    seeded = %Firehose{
      events_etag: "retained-etag",
      events_last_id: "retained-id",
      firehose_partial_streak: 4,
      firehose_truncation_alert_active: true,
      firehose_truncation_alert_resolution_emitted: true,
      recent_merge_persistence_failures: 2
    }

    :sys.replace_state(listener, fn _ -> seeded end)
    %{listener: listener, seeded: seeded}
  end

  test "raised read preserves listener state and records one failure before continuing", %{listener: listener, seeded: seeded} do
    parent = self()

    state =
      FirehosePolling.start(
        %State{},
        fn current ->
          send(parent, {:continued, current})
          current
        end,
        &TrackerTasks.start/4,
        server: listener,
        token: "test-token",
        request_fun: fn _ -> raise "read failed" end
      )

    [{ref, _}] = Map.to_list(state.tracker_tasks)
    next = complete_task(state, ref)
    receive_barrier({:continued, continued})
    assert next == continued
    assert next.github_connectivity == %{firehose: {:unclassified, 1}}
    assert next.tracker_tasks == %{}
    refute_received {:continued, _}
    assert Process.alive?(listener)
    assert :sys.get_state(listener) == seeded
  end

  test "a queued poll progresses with the retained etag after worker failure", %{listener: listener} do
    parent = self()

    first =
      :gen_server.send_request(
        listener,
        {:poll,
         [
           token: "test-token",
           request_fun: fn _ ->
             send(parent, {:held_read, self()})

             receive do
               :crash -> raise "read failed"
             end
           end
         ]}
      )

    receive_barrier({:held_read, worker})
    on_exit(fn -> Process.exit(worker, :kill) end)

    queued =
      :gen_server.send_request(
        listener,
        {:poll,
         [
           token: "test-token",
           request_fun: fn request ->
             send(parent, {:queued_request, request})
             {:ok, %{status: 304, headers: [], body: ""}}
           end
         ]}
      )

    assert :queue.len(:sys.get_state(listener).poll_queue) == 1
    send(worker, :crash)
    assert {:reply, {:error, {:tracker_task_exit, {%RuntimeError{message: "read failed"}, _}}}} = :gen_server.wait_response(first, :infinity)
    assert {:reply, %{connectivity: [{:firehose, :ok}], poll_interval: 60}} = :gen_server.wait_response(queued, :infinity)
    assert_received {:queued_request, %{etag: "retained-etag"}}
    assert Process.alive?(listener)
    assert :sys.get_state(listener).events_last_id == "retained-id"
    assert :sys.get_state(listener).pending_poll == nil
    assert :queue.is_empty(:sys.get_state(listener).poll_queue)
  end

  defp complete_task(state, ref) do
    receive do
      {^ref, outcome} ->
        assert {:error, {:tracker_task_exit, {%RuntimeError{message: "read failed"}, _}}} = outcome
        {:handled, next} = TrackerTasks.result(state, ref, outcome)
        next

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:handled, next} = TrackerTasks.down(state, ref, reason)
        next
    end
  end
end
