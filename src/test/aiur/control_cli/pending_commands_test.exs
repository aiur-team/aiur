Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.ControlCLI.PendingCommandsTest do
  use Aiur.DecisionStoreCase, async: false
  import ExUnit.CaptureIO
  alias Aiur.CommandsCLI
  alias Aiur.ControlCLI.ExecutorRequest
  alias Aiur.ControlCLI.PendingCommands

  @server __MODULE__.PendingCommands

  setup %{dir: dir} do
    previous = Application.get_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(dir, "executor"))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :executor_state_dir, previous), else: Application.delete_env(:aiur, :executor_state_dir)
    end)

    # The fake tracker: ticket id => closure result; unknown ids are open. Every read is counted.
    {:ok, tracker} = Agent.start_link(fn -> %{closures: %{}, reads: []} end)
    %{store: start_supervised_store!(dir), tracker: tracker, path: Path.join(dir, "pending-commands.json")}
  end

  defp set(tracker, id, result), do: Agent.update(tracker, &put_in(&1, [:closures, id], result))
  defp merged(tracker, id), do: set(tracker, id, {:ok, %{open?: false, state_reason: "completed"}})
  defp closed(tracker, id, reason), do: set(tracker, id, {:ok, %{open?: false, state_reason: reason}})
  defp reads(tracker), do: tracker |> Agent.get(& &1.reads) |> Enum.reverse()
  defp reset_reads(tracker), do: Agent.update(tracker, &%{&1 | reads: []})

  defp start_pending(%{store: store, tracker: tracker, path: path}, opts \\ []) do
    closure = fn id ->
      Agent.get_and_update(tracker, fn state -> {Map.get(state.closures, id, {:ok, %{open?: true, state_reason: nil}}), %{state | reads: [id | state.reads]}} end)
    end

    base = [name: @server, path: path, subscribe_fun: fn -> :ok end, closure_fun: closure, request_deps: [decision_store: store]]
    start_supervised!({PendingCommands, Keyword.merge(base, opts)}, id: Keyword.get(opts, :child_id, @server))
  end

  # The daemon's own event, delivered the way the Exchange delivers it.
  defp event(topic) do
    send(Process.whereis(@server), {:event, %{topic: topic}})
    :sys.get_state(@server)
  end

  defp cli_request(store, extra \\ []) do
    params = Keyword.merge([question: "Which build feels better?", options: ["a=First", "b=Second"], executor_id: "requester", after: "5,#6", json: true], extra)
    out = capture_io(fn -> send(self(), {:code, ExecutorRequest.request(params, decision_store: store, pending_server: @server)}) end)
    assert_received {:code, code}
    {code, out}
  end

  defp pending!(store, extra \\ []) do
    {0, out} = cli_request(store, extra)
    Jason.decode!(out)
  end

  test "a Command with --after 5,6 reaches no inbox until both merge, reading GitHub only on events", %{store: store, tracker: tracker} = ctx do
    start_pending(ctx)
    result = pending!(store)
    assert %{"status" => "pending", "after" => ["5", "6"]} = result
    assert reads(tracker) == ["5", "6"]
    reset_reads(tracker)

    event("ticket.9.pr.merged")
    assert reads(tracker) == []

    merged(tracker, "5")
    event("ticket.5.pr.merged")
    assert reads(tracker) == ["5"]
    assert DecisionStore.list(store) == []

    # A merged blocker is not read again.
    event("ticket.5.issue.label.added.agent.done")
    assert reads(tracker) == ["5"]

    merged(tracker, "6")
    event("ticket.6.issue.label.added.agent.done")
    assert reads(tracker) == ["5", "6"]
    assert [decision] = DecisionStore.list(store)
    assert decision.question == "Which build feels better?"
    assert decision.source.event_id == result["source_id"]
    assert PendingCommands.list(@server) == []
  end

  test "every closure but completed drops the Command and raises an Executor attention", %{store: store, tracker: tracker} = ctx do
    :ok = Exchange.subscribe("ticket.*.agent.attention.command_dropped")
    start_pending(ctx)

    for {reason, label} <- [{"not_planned", "not_planned"}, {nil, "closed_without_reason"}, {"reopened", "reopened"}] do
      %{"pending_id" => id} = pending!(store)
      merged(tracker, "5")
      closed(tracker, "6", reason)
      event("ticket.6.issue.label.added.agent.cancelled")

      assert PendingCommands.list(@server) == []
      assert DecisionStore.list(store) == []
      assert_receive {:event, %{:topic => "ticket.6.agent.attention.command_dropped", "message" => message, "needs_attention" => true}}
      assert message =~ "Pending Command #{id} dropped: ticket 6 #{label}"
      Agent.update(tracker, &%{&1 | closures: %{}})
    end

    # A blocker that is later deleted drops the Command too.
    pending!(store)
    set(tracker, "5", {:error, :not_found})
    event("ticket.5.pr.merged")
    assert PendingCommands.list(@server) == []
    assert_receive {:event, %{:topic => "ticket.5.agent.attention.command_dropped", "message" => message, "needs_attention" => true}}
    assert message =~ "ticket 5 not_found"
  end

  test "a dropped Command stays stored until its attention is recorded", %{store: store, tracker: tracker} = ctx do
    {:ok, outcomes} = Agent.start_link(fn -> [{:error, :ledger_unavailable}, :ok] end)
    wake = fn _entry, _blocker, _reason -> Agent.get_and_update(outcomes, fn [next | rest] -> {next, rest} end) end
    start_pending(ctx, wake_fun: wake, retry_ms: :timer.hours(1))
    pending!(store)

    closed(tracker, "6", "not_planned")
    event("ticket.6.pr.merged")
    assert [%{"dropped" => %{"blocker" => "6", "reason" => "not_planned"}}] = PendingCommands.list(@server)

    reset_reads(tracker)
    send(Process.whereis(@server), :retry)
    assert PendingCommands.list(@server) == []
    assert reads(tracker) == []
  end

  test "a pending Command survives a daemon restart and settles from one boot read", %{store: store, tracker: tracker} = ctx do
    start_pending(ctx)
    %{"pending_id" => pending_id} = pending!(store)
    stop_supervised!(@server)

    start_pending(ctx, child_id: :restarted)
    :sys.get_state(@server)
    assert [%{"id" => ^pending_id, "after" => ["5", "6"]}] = PendingCommands.list(@server)
    stop_supervised!(:restarted)

    merged(tracker, "5")
    merged(tracker, "6")
    reset_reads(tracker)
    start_pending(ctx, child_id: :restarted_again)
    :sys.get_state(@server)
    assert [%{question: "Which build feels better?"}] = DecisionStore.list(store)
    assert Enum.sort(reads(tracker)) == ["5", "6"]
  end

  test "request time refuses unknown tickets, unmerged closures and trackers without closure", %{store: store, tracker: tracker} = ctx do
    start_pending(ctx)

    for {result, message} <- [
          {{:error, :not_found}, "ticket 6 was not found"},
          {{:ok, %{open?: false, state_reason: "not_planned"}}, "ticket 6 is already closed without merging (not_planned)"},
          {{:error, :unsupported}, "cannot report ticket closure"}
        ] do
      set(tracker, "6", result)
      err = capture_io(:stderr, fn -> assert {64, _out} = cli_request(store) end)
      assert err =~ message
      assert PendingCommands.list(@server) == []
    end

    params = [question: "Q?", executor_id: "requester", after: "5,,x y"]
    assert capture_io(:stderr, fn -> send(self(), {:code, ExecutorRequest.request(params, decision_store: store, pending_server: @server)}) end) =~ "--after expects"
    assert_received {:code, 64}
  end

  test "blockers that already merged publish at once", %{store: store, tracker: tracker} = ctx do
    start_pending(ctx)
    merged(tracker, "5")
    merged(tracker, "6")
    assert %{"status" => "published"} = pending!(store)
    assert [%{question: "Which build feels better?"}] = DecisionStore.list(store)
    assert PendingCommands.list(@server) == []
  end

  test "aiur command cancel removes a pending Command so a later merge publishes nothing", %{store: store, tracker: tracker} = ctx do
    start_pending(ctx)
    %{"pending_id" => id} = pending!(store)

    assert capture_io(fn -> assert 0 == ExecutorRequest.cancel([pending_id: id], pending_server: @server) end) =~ "Cancelled pending Command #{id}"
    merged(tracker, "5")
    merged(tracker, "6")
    event("ticket.6.pr.merged")
    assert DecisionStore.list(store) == []

    assert capture_io(:stderr, fn -> assert 64 == ExecutorRequest.cancel([pending_id: id], pending_server: @server) end) =~ "found no pending Command"
  end

  test "aiur command lists pending Commands with their blockers, and says when the store is unavailable", %{store: store} = ctx do
    start_pending(ctx)
    pending!(store, short_summary: "Build comparison")

    listing = capture_io(fn -> CommandsCLI.run(decision_store: store, pending_fun: fn -> PendingCommands.list(@server) end) end)
    assert listing =~ ~r/pend_\w+  after #5, #6  Build comparison/

    down = capture_io(fn -> CommandsCLI.run(decision_store: store, pending_fun: fn -> exit(:noproc) end) end)
    assert down =~ "Pending Commands: unavailable"
  end
end
