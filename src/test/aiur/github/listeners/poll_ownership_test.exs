defmodule Aiur.GitHub.Listeners.PollOwnershipTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Listeners
  alias Aiur.GitHub.Listeners.Firehose

  setup do
    previous = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")
    on_exit(fn -> restore_env("GITHUB_TOKEN", previous) end)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    Listeners.reset()
    :ok
  end

  # Future regression guard: the old inline listener also serialized cursors.
  test "queued polls inherit the preceding poll's cursor" do
    parent = self()

    first =
      Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn ->
        Listeners.poll_firehose(
          request_fun: fn _ ->
            send(parent, {:first_read, self()})

            receive do
              :release ->
                {:ok, %{status: 200, headers: [{"ETag", "first"}], body: [%{"id" => "first-id", "type" => "IssuesEvent", "payload" => %{}}]}}
            end
          end
        )
      end)

    receive_barrier({:first_read, worker})
    on_exit(fn -> send(worker, :release) end)

    request =
      :gen_server.send_request(
        Firehose,
        {:poll,
         [
           request_fun: fn req ->
             send(parent, {:queued_etag, req.etag})
             {:ok, %{status: 304, headers: [{"ETag", "second"}], body: ""}}
           end
         ]}
      )

    send(worker, :release)
    assert Task.await(first).connectivity == [{:firehose, :ok}]
    assert {:reply, %{connectivity: [{:firehose, :ok}]}} = :gen_server.receive_response(request, :infinity)
    assert_received {:queued_etag, "first"}
    assert :sys.get_state(Firehose).events_etag == "second"
    assert :sys.get_state(Firehose).events_last_id == "first-id"
  end

  # Future regression guard: supervisor shutdown previously killed the inline read.
  @tag timeout: 5_000
  test "listener shutdown reaps its held poll worker" do
    listener = start_supervised!({Firehose, []})
    parent = self()

    poll =
      Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn ->
        Listeners.poll_firehose(
          server: listener,
          request_fun: fn _ ->
            send(parent, {:held_read, self()})

            receive do
              :release -> {:ok, %{status: 304, headers: [], body: ""}}
            end
          end
        )
      end)

    receive_barrier({:held_read, worker})
    on_exit(fn -> send(worker, :release) end)
    monitor = Process.monitor(worker)
    assert :ok = stop_supervised(Firehose)
    receive_barrier({:DOWN, ^monitor, :process, ^worker, _reason})
    assert catch_exit(Task.await(poll))
  end
end
