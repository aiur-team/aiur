defmodule Aiur.ExecutorAttention.CLITest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI
  alias Aiur.Executor.{Claims, StatePaths}
  alias Aiur.ExecutorWakeInbox

  test "executor-wait prints and acknowledges a pending wake" do
    start_supervised!({ExecutorWakeInbox, debounce_ms: 0})

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    :ok =
      ExecutorWakeInbox.enqueue(%{
        "wake_id" => 1,
        "event_id" => 1,
        "topic" => "ticket.42.pr.opened",
        "topic_class" => "ticket.pr.opened",
        "ticket" => "42",
        "count" => 1,
        "first_seen_at" => now,
        "last_seen_at" => now
      })

    output = capture_io(fn -> AgentControlCLI.executor_wait(timeout_ms: 500, json: true) end)

    assert output =~ ~s("topic":"ticket.42.pr.opened")
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    assert ExecutorWakeInbox.pending() == []
  end

  test "executor-wait renders initial sync only on backfilled wakes" do
    start_supervised!({ExecutorWakeInbox, debounce_ms: 0})

    backfill =
      wake_record(1, "42", "ticket.42.pr.ready_for_review", "ticket.pr.ready_for_review")
      |> Map.put("observation", "initial_sync")

    :ok = ExecutorWakeInbox.enqueue(backfill)
    :ok = ExecutorWakeInbox.enqueue(wake_record(2, "43", "ticket.43.pr.ready_for_review", "ticket.pr.ready_for_review"))

    output = capture_io(fn -> AgentControlCLI.executor_wait(timeout_ms: 500) end)

    assert output =~ ~r/^WAKE ticket.42.pr.ready_for_review .* observation=initial_sync$/m
    assert output =~ ~r/^WAKE ticket.43.pr.ready_for_review .* role=owner$/m
    assert ExecutorWakeInbox.pending() == []
  end

  test "executor-wait reports a quiet timeout as a successful empty result (#2600)" do
    start_supervised!({ExecutorWakeInbox, debounce_ms: 0})

    output = capture_io(fn -> AgentControlCLI.executor_wait(timeout_ms: 20, json: true) end)
    cursor_path = StatePaths.cursor_path()

    # A wait that consumed nothing and lost nothing is not a failure. It used to
    # exit 75 with no output at all, which the launcher could only report as
    # "failed with exit 75 and returned no diagnostic output".
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    assert output =~ ~s("status":"timeout")
    assert output =~ ~s("records":[])
    refute output =~ "WAKE "
    refute output =~ "__AIUR_CONTROL_ERROR__"
    refute File.exists?(cursor_path)
  end

  test "executor-wait reports a quiet timeout in plain mode too (#2600)" do
    start_supervised!({ExecutorWakeInbox, debounce_ms: 0})

    output = capture_io(fn -> AgentControlCLI.executor_wait(timeout_ms: 20) end)

    assert output =~ "NO-WAKES role=owner timeout_ms=20"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "executor-wait returns a wake enqueued during the wait and advances the cursor (#2600)" do
    # A debounce longer than the wait forces the flush to land at expiry, which
    # is the live-run shape that yielded blank output while the ledger held
    # unconsumed records moments later.
    start_supervised!({ExecutorWakeInbox, debounce_ms: 5_000})

    waiter =
      Task.async(fn ->
        capture_io(fn -> AgentControlCLI.executor_wait(timeout_ms: 300, json: true, as: "late-wake") end)
      end)

    Process.sleep(30)
    :ok = ExecutorWakeInbox.enqueue(wake_record(1, "2600", "ticket.2600.ci.passed", "ticket.ci.passed"))

    output = Task.await(waiter, 5_000)

    assert output =~ ~s("topic":"ticket.2600.ci.passed")
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    assert ExecutorWakeInbox.pending() == []
    assert ExecutorWakeInbox.cursor() == 1
  end

  test "executor-wait names the claim stage and the retry bounds under lock contention (#2600)" do
    start_supervised!({ExecutorWakeInbox, debounce_ms: 0})
    put_claims_lock_timeout(100)
    lock = StatePaths.claims_path() <> ".lock"
    File.write!(lock, "held by a peer")
    on_exit(fn -> File.rm(lock) end)

    output = capture_io(fn -> AgentControlCLI.executor_wait(timeout_ms: 20, json: true) end)

    assert output =~ "__AIUR_CONTROL_EXIT__:69"
    assert output =~ ~s("stage":"claim")
    assert output =~ "wake-stream lock contention"
    assert output =~ "retrying every 25ms for 100ms"
    assert output =~ "a lock older than 60s is broken as stale"
    assert output =~ "safe to retry"
  end

  test "executor-wait names the acknowledge stage when a peer took the claim mid-wait (#2600)" do
    start_supervised!({ExecutorWakeInbox, debounce_ms: 0})

    waiter =
      Task.async(fn ->
        capture_io(fn -> AgentControlCLI.executor_wait(timeout_ms: 5_000, json: true, as: "displaced-owner") end)
      end)

    # Barrier on observed state, not on a sleep: the takeover below is only the
    # scenario under test once this consumer's own claim has actually landed.
    assert await_consumer("displaced-owner")
    {:ok, _revoked} = Claims.revoke("displaced-owner")
    {:ok, _peer} = Claims.claim("live-peer")

    :ok = ExecutorWakeInbox.enqueue(wake_record(1, "2600", "ticket.2600.pr.opened", "ticket.pr.opened"))
    output = Task.await(waiter, 20_000)

    assert output =~ "__AIUR_CONTROL_EXIT__:69"
    assert output =~ ~s("stage":"acknowledge")
    assert output =~ ~s("unconsumed_wake_ids":[1])
    assert output =~ "cursor-write contention"
    assert output =~ "live-peer"
    assert output =~ "were NOT consumed"
    # The batch is still printed — losing a wake is worse than announcing a
    # redelivery — but the nonzero exit and the named ids say it was not
    # consumed, where this used to be an undiagnosed exit 0.
    assert output =~ ~s("topic":"ticket.2600.pr.opened")
    assert output =~ ~s("status":"woken")
    assert ExecutorWakeInbox.cursor() == 0
    assert [%{"wake_id" => 1}] = ExecutorWakeInbox.pending()
  end

  for prior_role <- ["owner", "observer"] do
    test "renewer switches a displaced #{prior_role} wait to observer without acknowledging" do
      start_supervised!({ExecutorWakeInbox, debounce_ms: 0})
      waiter = Task.async(fn -> capture_io(fn -> AgentControlCLI.executor_wait(timeout_ms: 5_000, json: true, as: "old-owner") end) end)
      await_executor_wait(waiter.pid)
      {:ok, old} = Claims.owner()
      {:ok, _} = Claims.revoke("old-owner")
      {:ok, successor} = Claims.claim("successor")
      expired = old |> Map.put("lease_expires_at", "2000-01-01T00:00:00Z") |> Map.put("role", unquote(prior_role))
      Aiur.JsonStore.write!(StatePaths.claims_path(), %{"consumers" => %{"old-owner" => expired, "successor" => successor}})
      {:links, links} = Process.info(waiter.pid, :links)
      renewer = Enum.find(links, &(&1 != self()))
      :erlang.trace_pattern({Aiur.ExecutorAttention.CLI, :renew_lease_forever, 3}, true, [:local])
      :erlang.trace(renewer, true, [:send, :call])
      on_exit(fn -> :erlang.trace_pattern({Aiur.ExecutorAttention.CLI, :renew_lease_forever, 3}, false, [:local]) end)
      send(renewer, :renew)
      receive_barrier({:trace, ^renewer, :call, {Aiur.ExecutorAttention.CLI, :renew_lease_forever, _args}})
      assert_received {:trace, ^renewer, :send, {:executor_ownership_lost, ^renewer}, _destination}
      :erlang.trace(renewer, false, [:send, :call])

      :ok = ExecutorWakeInbox.enqueue(wake_record(1, "3412", "ticket.3412.pr.opened", "ticket.pr.opened"))
      output = Task.await(waiter)
      assert output =~ "not the live owner"
      assert output =~ ~s("role":"observer")
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
      assert ExecutorWakeInbox.cursor() == 0
      assert [%{"wake_id" => 1}] = ExecutorWakeInbox.pending()
    end
  end

  test "executor-wait separates a store failure from contention with exit 1 (#2600)" do
    start_supervised!({ExecutorWakeInbox, debounce_ms: 0})
    # An unreadable ledger is a daemon/store failure, not something a caller can
    # retry through, so it must not share the retryable contention exit code.
    File.write!(StatePaths.wakes_path(), ~s({"wake_id":0,"event_id":1,"topic":"bad"}\n), [:append])

    output = capture_io(fn -> AgentControlCLI.executor_wait(timeout_ms: 20, json: true, as: "corrupt-ledger") end)

    assert output =~ "__AIUR_CONTROL_EXIT__:1"
    assert output =~ ~s("stage":"wait")
    assert output =~ "executor wake inbox unavailable"
    refute output =~ "__AIUR_CONTROL_EXIT__:69"
  end

  defp await_executor_wait(pid) do
    if Enum.any?(:sys.get_state(ExecutorWakeInbox).waiters, fn {{waiter, _tag}, _} -> waiter == pid end),
      do: :ok,
      else: await_executor_wait(pid)
  end

  defp await_consumer(id, attempts \\ 200) do
    Enum.any?(1..attempts, fn _attempt ->
      if Enum.any?(Claims.entries(), &(&1["id"] == id)) do
        true
      else
        Process.sleep(10)
        false
      end
    end)
  end

  defp put_claims_lock_timeout(timeout_ms) do
    previous = Application.get_env(:aiur, :executor_claims_lock_timeout_ms)
    Application.put_env(:aiur, :executor_claims_lock_timeout_ms, timeout_ms)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:aiur, :executor_claims_lock_timeout_ms)
        value -> Application.put_env(:aiur, :executor_claims_lock_timeout_ms, value)
      end
    end)
  end

  defp wake_record(wake_id, ticket, topic, topic_class) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      "wake_id" => wake_id,
      "event_id" => wake_id,
      "topic" => topic,
      "topic_class" => topic_class,
      "ticket" => ticket,
      "count" => 1,
      "first_seen_at" => now,
      "last_seen_at" => now
    }
  end

  test "executor-fast-forward acknowledges an externally covered wake prefix" do
    start_supervised!({ExecutorWakeInbox, debounce_ms: 0})

    for id <- 1..3 do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      :ok =
        ExecutorWakeInbox.enqueue(%{
          "wake_id" => id,
          "event_id" => id,
          "topic" => "ticket.#{id}.branch.push",
          "topic_class" => "ticket.branch.push",
          "ticket" => Integer.to_string(id),
          "count" => 1,
          "first_seen_at" => now,
          "last_seen_at" => now
        })
    end

    Process.sleep(20)
    assert length(ExecutorWakeInbox.pending()) == 3

    output = capture_io(fn -> AgentControlCLI.executor_fast_forward(2, as: "covered-window") end)

    assert output =~ "FAST-FORWARDED from=0 through=2 acknowledged=2 pending=1"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    assert Enum.map(ExecutorWakeInbox.pending(), & &1["wake_id"]) == [3]
  end
end
