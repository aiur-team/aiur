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
               seen_path: seen_path(),
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
               seen_path: seen_path(),
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
               seen_path: seen_path(),
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

    assert {:ok, pid} = ExecutorSweep.start_link(name: nil, seen_path: seen_path(), interval_ms: 60_000, sweep_fun: sweep, publish_fun: &send(parent, {:finding, &1}))
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
                   seen_path: seen_path(),
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
    assert {:ok, pid} = ExecutorSweep.start_link(name: nil, seen_path: seen_path(), interval_ms: 0, sweep_fun: fn -> send(parent, :swept) && [] end)
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
               seen_path: seen_path(),
               interval_ms: 60_000,
               sweep_fun: fn -> [finding] end,
               publish_fun: &Wake.publish(&1, inbox)
             )

    assert {:ok, [%{"topic" => "ticket.4429.agent.executor-sweep.finding", "pull_request" => 4447, "needs_attention" => true}]} =
             Aiur.ExecutorWakeInbox.wait(1_000, inbox)

    GenServer.stop(sweep)
    GenServer.stop(inbox)
  end

  test "a restarted sweep publishes only findings that changed while it was down" do
    parent = self()
    path = seen_path()
    {:ok, findings} = Agent.start_link(fn -> [%{kind: "sample", ticket: 1}] end)
    start = fn -> ExecutorSweep.start_link(name: nil, seen_path: path, interval_ms: 60_000, sweep_fun: fn -> Agent.get(findings, & &1) end, publish_fun: &send(parent, {:finding, &1})) end

    assert {:ok, pid} = start.()
    assert_receive {:finding, %{ticket: 1}}, 1_000
    _ = :sys.get_state(pid)
    GenServer.stop(pid)

    assert {:ok, pid} = start.()
    _ = :sys.get_state(pid)
    refute_receive {:finding, _}, 50
    GenServer.stop(pid)

    Agent.update(findings, &[%{kind: "sample", ticket: 2} | &1])
    assert {:ok, pid} = start.()
    assert_receive {:finding, %{ticket: 2}}, 1_000
    _ = :sys.get_state(pid)
    refute_receive {:finding, _}, 50
    GenServer.stop(pid)
    Agent.stop(findings)
  end

  test "a first start without a seen file records the backlog and publishes only later findings" do
    parent = self()
    path = fresh_seen_path()
    {:ok, findings} = Agent.start_link(fn -> Enum.map(1..300, &%{kind: "invalid_state_labels", ticket: &1}) end)

    assert {:ok, pid} = ExecutorSweep.start_link(name: nil, seen_path: path, interval_ms: 60_000, sweep_fun: fn -> Agent.get(findings, & &1) end, publish_fun: &send(parent, {:finding, &1}))
    _ = :sys.get_state(pid)
    refute_receive {:finding, _}, 50
    assert File.exists?(path)

    Agent.update(findings, &[%{kind: "sample", ticket: 301} | &1])
    send(pid, :sweep)
    assert_receive {:finding, %{ticket: 301}}, 1_000
    send(pid, :sweep)
    _ = :sys.get_state(pid)
    refute_receive {:finding, _}, 50
    GenServer.stop(pid)
    Agent.stop(findings)
  end

  @ticket %{kind: "invalid_state_labels", ticket: 7}
  @unavailable %{kind: "sweep_source_unavailable", check: "ticket_hygiene", sources: [:tickets]}

  test "an unavailable ticket source keeps ticket fingerprints across a restart" do
    parent = self()
    path = seen_path()
    {:ok, findings} = Agent.start_link(fn -> [@ticket] end)
    start = fn -> ExecutorSweep.start_link(name: nil, seen_path: path, interval_ms: 60_000, sweep_fun: fn -> Agent.get(findings, & &1) end, publish_fun: &send(parent, {:finding, &1})) end

    assert {:ok, pid} = start.()
    assert_receive {:finding, @ticket}, 1_000
    Agent.update(findings, fn _ -> [@unavailable] end)
    send(pid, :sweep)
    assert_receive {:finding, @unavailable}, 1_000
    GenServer.stop(pid)

    # Restarted while the source is still listing; the ticket finding returns once it is listed.
    assert {:ok, pid} = start.()
    _ = :sys.get_state(pid)
    Agent.update(findings, fn _ -> [@ticket] end)
    send(pid, :sweep)
    _ = :sys.get_state(pid)
    refute_receive {:finding, _}, 50
    GenServer.stop(pid)
    Agent.stop(findings)
  end

  test "a first start keeps quiet until the ticket source has been listed once" do
    parent = self()
    {:ok, findings} = Agent.start_link(fn -> [@unavailable] end)

    assert {:ok, pid} =
             ExecutorSweep.start_link(name: nil, seen_path: fresh_seen_path(), interval_ms: 60_000, sweep_fun: fn -> Agent.get(findings, & &1) end, publish_fun: &send(parent, {:finding, &1}))

    _ = :sys.get_state(pid)
    Agent.update(findings, fn _ -> [@ticket] end)
    send(pid, :sweep)
    _ = :sys.get_state(pid)
    refute_receive {:finding, _}, 50
    GenServer.stop(pid)
    Agent.stop(findings)
  end

  defp seen_path do
    path = fresh_seen_path()
    File.write!(path, "[]")
    path
  end

  defp fresh_seen_path do
    root = Aiur.TestSupport.tmp_root!("aiur-executor-sweep-seen")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    File.mkdir_p!(root)
    Path.join(root, "seen.json")
  end
end
