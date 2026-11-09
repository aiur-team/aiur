Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.DeferredTest do
  use Aiur.DecisionStoreCase, async: false
  import ExUnit.CaptureIO
  alias Aiur.Commands.Deferred
  alias Aiur.CommandsCLI
  alias Aiur.ControlCLI.ExecutorRequest
  alias Aiur.ExecutorListener
  alias Aiur.ExecutorWakeInbox

  @server __MODULE__.Deferred
  @inbox __MODULE__.Inbox

  setup %{dir: dir} do
    previous = Application.get_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(dir, "executor"))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :executor_state_dir, previous), else: Application.delete_env(:aiur, :executor_state_dir)
    end)

    # The fake tracker: every ticket starts open.
    {:ok, tracker} = Agent.start_link(fn -> %{} end)
    %{store: start_supervised_store!(dir), tracker: tracker, path: Path.join(dir, "pending-commands.json")}
  end

  defp close(tracker, id, reason), do: Agent.update(tracker, &Map.put(&1, id, reason))

  defp start_deferred(%{store: store, tracker: tracker, path: path}, id \\ @server) do
    closure = fn id ->
      case Agent.get(tracker, &Map.get(&1, id)) do
        nil -> {:ok, %{open?: true, state_reason: nil}}
        reason -> {:ok, %{open?: false, state_reason: reason}}
      end
    end

    start_supervised!({Deferred, name: @server, path: path, poll_ms: :infinity, closure_fun: closure, request_deps: [decision_store: store]}, id: id)
  end

  defp cli_request(store, extra \\ []) do
    params = Keyword.merge([question: "Which build feels better?", options: ["a=First", "b=Second"], executor_id: "requester", after: "5,#6", json: true], extra)
    output = capture_io(fn -> send(self(), {:code, ExecutorRequest.request(params, decision_store: store, deferred_server: @server)}) end)
    assert_received {:code, 0}
    Jason.decode!(output)
  end

  test "a Command with --after 5,6 reaches no inbox until both merge, then publishes once", %{store: store, tracker: tracker} = ctx do
    start_deferred(ctx)
    result = cli_request(store)
    assert result["status"] == "pending"
    assert result["after"] == ["5", "6"]

    Deferred.poll(@server)
    assert DecisionStore.list(store) == []

    close(tracker, "5", "completed")
    Deferred.poll(@server)
    assert DecisionStore.list(store) == []

    close(tracker, "6", "completed")
    Deferred.poll(@server)
    assert [decision] = DecisionStore.list(store)
    assert decision.question == "Which build feels better?"
    assert decision.source.event_id == result["source_id"]
    assert Deferred.list(@server) == []

    Deferred.poll(@server)
    assert length(DecisionStore.list(store)) == 1
  end

  test "closing a blocker as not planned drops the Command and wakes the Executor", %{store: store, tracker: tracker} = ctx do
    start_supervised!({ExecutorWakeInbox, name: @inbox, debounce_ms: 0})
    start_supervised!({ExecutorListener, name: __MODULE__.Listener, inbox: @inbox, resubscribe_interval_ms: :infinity})
    start_deferred(ctx)
    %{"pending_id" => pending_id} = cli_request(store)

    close(tracker, "5", "completed")
    close(tracker, "6", "not_planned")
    Deferred.poll(@server)

    assert Deferred.list(@server) == []
    assert DecisionStore.list(store) == []
    assert {:ok, [wake]} = ExecutorWakeInbox.wait(5_000, @inbox)
    assert %{"topic" => "executor.command.dropped", "action" => "dropped", "pending_id" => ^pending_id, "blocker" => "6", "reason" => "not_planned"} = wake
  end

  test "a pending Command survives a daemon restart", %{store: store, tracker: tracker} = ctx do
    start_deferred(ctx)
    %{"pending_id" => pending_id} = cli_request(store)
    stop_supervised!(@server)

    start_deferred(ctx, :restarted)
    assert [%{"id" => ^pending_id, "after" => ["5", "6"]}] = Deferred.list(@server)

    close(tracker, "5", "completed")
    close(tracker, "6", "completed")
    Deferred.poll(@server)
    assert [%{question: "Which build feels better?"}] = DecisionStore.list(store)
  end

  test "aiur command lists pending Commands with their blockers, and says when the store is unavailable", %{store: store} = ctx do
    start_deferred(ctx)
    cli_request(store, short_summary: "Build comparison")

    listing = capture_io(fn -> CommandsCLI.run(decision_store: store, pending_fun: fn -> Deferred.list(@server) end) end)
    assert listing =~ ~r/pend_\w+  after #5, #6  Build comparison/

    down = capture_io(fn -> CommandsCLI.run(decision_store: store, pending_fun: fn -> exit(:noproc) end) end)
    assert down =~ "Pending Commands: unavailable"
  end

  test "--after refuses malformed ticket lists before storing anything", %{store: store} = ctx do
    start_deferred(ctx)
    params = [question: "Q?", executor_id: "requester", after: "5,,x y"]
    assert capture_io(:stderr, fn -> send(self(), {:code, ExecutorRequest.request(params, decision_store: store, deferred_server: @server)}) end) =~ "--after expects"
    assert_received {:code, 64}
    assert Deferred.list(@server) == []
  end
end
