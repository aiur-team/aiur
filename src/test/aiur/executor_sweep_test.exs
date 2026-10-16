defmodule Aiur.ExecutorSweepTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Aiur.ExecutorSweep
  alias Aiur.ExecutorSweep.Wake

  test "timer publishes each new finding once" do
    parent = self()
    finding = %{kind: "sample", priority: 1, message: "action"}

    assert {:ok, pid} =
             ExecutorSweep.start_link(
               name: nil,
               interval_ms: 60_000,
               sweep_fun: fn -> [finding] end,
               publish_fun: fn value -> send(parent, {:finding, value}) end
             )

    assert_receive {:finding, ^finding}, 1_000
    send(pid, :sweep)
    refute_receive {:finding, ^finding}, 50
    GenServer.stop(pid)
  end

  test "timer deduplicates a finding as its age changes between sweeps" do
    parent = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    assert {:ok, pid} =
             ExecutorSweep.start_link(
               name: nil,
               interval_ms: 60_000,
               sweep_fun: fn ->
                 age = Agent.get_and_update(counter, fn value -> {value, value + 1} end)
                 [%{kind: "unreviewed_human_review_pr", pull_request: 4447, age_ms: age}]
               end,
               publish_fun: fn value -> send(parent, {:finding, value}) end
             )

    assert_receive {:finding, %{age_ms: 0}}, 1_000
    send(pid, :sweep)
    refute_receive {:finding, _}, 50
    GenServer.stop(pid)
    Agent.stop(counter)
  end

  test "timer wakes again when the PR head changes under the same finding" do
    parent = self()
    {:ok, head} = Agent.start_link(fn -> "head-1" end)

    assert {:ok, pid} =
             ExecutorSweep.start_link(
               name: nil,
               interval_ms: 60_000,
               sweep_fun: fn -> [%{kind: "unreviewed_human_review_pr", issue_number: 42, pull_request: 77, head_sha: Agent.get(head, & &1)}] end,
               publish_fun: fn value -> send(parent, {:finding, value}) end
             )

    assert_receive {:finding, %{head_sha: "head-1"}}, 1_000
    Agent.update(head, fn _ -> "head-2" end)
    send(pid, :sweep)
    assert_receive {:finding, %{head_sha: "head-2"}}, 1_000

    GenServer.stop(pid)
    Agent.stop(head)
  end

  test "a failing or exiting sweep keeps the process alive and the next sweep publishes" do
    parent = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    sweep = fn ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> raise "dependency not started"
        1 -> exit(:noproc)
        _ -> [%{kind: "sample"}]
      end
    end

    assert {:ok, pid} = ExecutorSweep.start_link(name: nil, interval_ms: 60_000, sweep_fun: sweep, publish_fun: &send(parent, {:finding, &1}))
    send(pid, :sweep)
    send(pid, :sweep)
    assert_receive {:finding, %{kind: "sample"}}, 1_000
    assert Process.alive?(pid)
    GenServer.stop(pid)
    Agent.stop(calls)
  end

  test "a skipped cycle logs a warning with the reason" do
    parent = self()

    log =
      capture_log(fn ->
        assert {:ok, pid} =
                 ExecutorSweep.start_link(
                   name: nil,
                   interval_ms: 60_000,
                   sweep_fun: fn ->
                     send(parent, :swept)
                     raise "dependency not started"
                   end
                 )

        assert_receive :swept, 1_000
        _ = :sys.get_state(pid)
        GenServer.stop(pid)
      end)

    assert log =~ "Executor sweep skipped a cycle: ** (RuntimeError) dependency not started"
  end

  test "a dropped wake logs a warning with the finding kind" do
    log = capture_log(fn -> assert :ok = Wake.publish(%{kind: "sample", issue_number: 7}, :no_such_inbox) end)
    assert log =~ ~s(Executor sweep wake dropped for "sample")
  end

  test "interval 0 starts idle" do
    parent = self()
    assert {:ok, pid} = ExecutorSweep.start_link(name: nil, interval_ms: 0, sweep_fun: fn -> send(parent, :swept) && [] end)
    refute_receive :swept, 50
    GenServer.stop(pid)
  end

  test "pure sweep runner accepts local snapshot inputs" do
    assert [] = ExecutorSweep.findings(snapshot: %{pull_requests: [], tickets: []}, now: ~U[2026-10-15 18:20:00Z])
  end

  test "timer findings enter the durable Executor wake inbox" do
    root = Aiur.TestSupport.tmp_root!("aiur-executor-sweep-wake")

    inbox_opts = [
      name: nil,
      debounce_ms: 0,
      path: Path.join(root, "wakes.ndjson"),
      cursor_path: Path.join(root, "cursor.json"),
      pending_path: Path.join(root, "pending.json")
    ]

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    assert {:ok, inbox} = Aiur.ExecutorWakeInbox.start_link(inbox_opts)
    finding = %{kind: "unreviewed_human_review_pr", priority: 1, issue_number: 4429, pull_request: 4447, age_ms: 900_000, message: "PR #4447 has waited 15m.", action: "Review it."}

    assert {:ok, sweep} =
             ExecutorSweep.start_link(
               name: nil,
               interval_ms: 60_000,
               sweep_fun: fn -> [finding] end,
               publish_fun: &Wake.publish(&1, inbox)
             )

    assert {:ok, [%{"topic" => "ticket.4429.agent.executor-sweep.finding", "pull_request" => 4447, "needs_attention" => true}]} =
             Aiur.ExecutorWakeInbox.wait(1_000, inbox)

    GenServer.stop(sweep)
    GenServer.stop(inbox)
  end
end
