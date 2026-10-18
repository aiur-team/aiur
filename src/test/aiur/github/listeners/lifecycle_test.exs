defmodule Aiur.GitHub.Listeners.LifecycleTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Listeners
  alias Aiur.GitHub.Listeners.Firehose
  alias Aiur.Orchestrator.{FirehosePolling, State, TrackerTasks}

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")
    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_token) end)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    Listeners.reset()
    :ok
  end

  test "reset makes the next request send nil etag and watermark" do
    seed_cursor()
    seed_latches()
    assert :sys.get_state(Firehose).events_last_id == "seen"
    assert :ok = Listeners.reset()
    assert_empty_cursor_request()
  end

  test "orchestrator init resets the surviving listener before another poll" do
    seed_cursor()
    seed_latches()
    listener = Process.whereis(Firehose)
    assert :sys.get_state(listener).events_etag == "seed-etag"
    start_supervised!({Aiur.Orchestrator, initial_poll?: false})
    assert Process.whereis(Firehose) == listener
    assert_empty_cursor_request()
  end

  test "firehose task returns immediately and applies health before continuing the dispatch chain" do
    parent = self()

    request = fn _ ->
      send(parent, {:poll_started, self()})

      receive do
        :finish_poll -> {:ok, %{status: 200, headers: [{"X-Poll-Interval", "13"}], body: []}}
      end
    end

    state =
      FirehosePolling.start(
        %State{},
        fn health ->
          send(parent, {:continued, health})
          health
        end,
        &TrackerTasks.start/4,
        request_fun: request
      )

    assert map_size(state.tracker_tasks) == 1
    receive_barrier({:poll_started, listener})
    refute_received {:continued, _}
    send(listener, :finish_poll)
    [{ref, _job}] = Map.to_list(state.tracker_tasks)
    receive_barrier({^ref, outcome})
    assert {:handled, next} = TrackerTasks.result(state, ref, outcome)
    assert next.tracker_tasks == %{}
    receive_barrier({:continued, continued})
    assert continued.github_poll_delays[:firehose] == 13_000
    assert continued.github_connectivity[:firehose] == nil
  end

  @tag timeout: 5_000
  test "reset cancels an in-flight poll without waiting for the external read" do
    parent = self()

    poll =
      Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn ->
        Listeners.poll_firehose(
          request_fun: fn _ ->
            send(parent, {:held_poll, self()})

            receive do
              :release_poll -> {:ok, %{status: 304, headers: [], body: ""}}
            end
          end
        )
      end)

    receive_barrier({:held_poll, worker})
    on_exit(fn -> send(worker, :release_poll) end)
    monitor = Process.monitor(worker)
    assert :ok = Listeners.reset()
    receive_barrier({:DOWN, ^monitor, :process, ^worker, _reason})
    assert Task.await(poll) == {:error, :firehose_reset}
    assert_empty_cursor_request()
  end

  @tag timeout: 5_000
  test "caller death cancels its held read and preserves the prior cursor" do
    seed_cursor()
    parent = self()

    poll =
      Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn ->
        Listeners.poll_firehose(
          request_fun: fn _ ->
            send(parent, {:held_read, self()})

            receive do
              :release_poll -> {:ok, %{status: 304, headers: [], body: ""}}
            end
          end
        )
      end)

    receive_barrier({:held_read, worker})
    on_exit(fn -> send(worker, :release_poll) end)
    monitor = Process.monitor(worker)
    Process.exit(poll.pid, :kill)
    receive_barrier({:DOWN, ^monitor, :process, ^worker, _reason})
    assert :sys.get_state(Firehose).events_etag == "seed-etag"
    assert :sys.get_state(Firehose).events_last_id == "seen"
  end

  test "outcome fold preserves failure then recovery order and applies the advertised interval" do
    outcome = %{connectivity: [{:firehose, {:error, {:github, :dns, %{}}}}, {:firehose, :ok}], poll_interval: 60}
    next = FirehosePolling.apply_outcome(%State{}, outcome)
    assert next.github_connectivity[:firehose] == nil
    assert next.github_poll_delays[:firehose] == 60_000
  end

  # Regression guard: an exit remains visible to callers rather than being rescued.
  test "a listener exit propagates to the caller" do
    pid = start_supervised!(Supervisor.child_spec({Firehose, []}, restart: :temporary))
    parent = self()

    poll =
      Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn ->
        catch_exit(
          Listeners.poll_firehose(
            server: pid,
            request_fun: fn _ ->
              send(parent, {:held_listener_read, self()})

              receive do
                :release_poll -> {:ok, %{status: 304, headers: [], body: ""}}
              end
            end
          )
        )
      end)

    receive_barrier({:held_listener_read, worker})
    on_exit(fn -> Process.exit(worker, :kill) end)
    monitor = Process.monitor(worker)
    Process.exit(pid, :kill)
    assert {:killed, {GenServer, :call, [^pid, {:poll, _opts}, :infinity]}} = Task.await(poll, :infinity)
    Process.exit(worker, :kill)
    receive_barrier({:DOWN, ^monitor, :process, ^worker, :killed})
  end

  defp seed_cursor do
    Listeners.poll_firehose(
      request_fun: fn _ ->
        {:ok, %{status: 200, headers: [{"ETag", "seed-etag"}], body: [%{"id" => "seen", "type" => "IssuesEvent", "payload" => %{}}]}}
      end
    )
  end

  defp seed_latches do
    :sys.replace_state(Firehose, fn state ->
      %{state | firehose_partial_streak: 4, firehose_truncation_alert_active: true, firehose_truncation_alert_resolution_emitted: true, recent_merge_persistence_failures: 2}
    end)
  end

  defp assert_empty_cursor_request do
    parent = self()

    Listeners.poll_firehose(
      request_fun: fn request ->
        send(parent, {:request, request})
        {:ok, %{status: 304, headers: [], body: ""}}
      end
    )

    assert_received {:request, %{etag: nil}}
    assert :sys.get_state(Firehose).recent_merge_persistence_failures == 0
    refute :sys.get_state(Firehose).firehose_truncation_alert_resolution_emitted
    assert :sys.get_state(Firehose).events_last_id == nil
    assert :sys.get_state(Firehose).firehose_partial_streak == 0
    refute :sys.get_state(Firehose).firehose_truncation_alert_active
  end
end
