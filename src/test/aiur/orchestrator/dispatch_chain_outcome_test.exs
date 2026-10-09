defmodule Aiur.Orchestrator.DispatchChainOutcomeTest do
  # #3683: the candidate batch is an asynchronous chain. A deep owner mailbox
  # used to end it silently, and its outcome was recorded before it ran, so an
  # eligible ticket with a free slot was reported as "empty ... :unknown".
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.{Dispatcher, State, TrackerTasks}

  test "an eligible ticket behind a deep-mailbox point is dispatched once the owner drains" do
    parent = self()
    first = %Issue{id: "chain-first", identifier: "repo#chain-first", title: "first", state: "todo", priority: 1}
    eligible = %Issue{id: "chain-eligible", identifier: "repo#chain-eligible", title: "eligible", state: "todo", priority: 2}

    fetcher = fn
      ["chain-first"] ->
        # A webhook burst lands in the owner's mailbox while this read runs.
        for _ <- 1..100, do: send(parent, :webhook_burst_3683)
        {:error, :controlled_failure}

      ["chain-eligible"] ->
        {:ok, [eligible]}
    end

    pending =
      Dispatcher.choose_issues(%State{snapshot_key: self(), max_concurrent_agents: 4, effective_concurrent_agents: 4}, [eligible, first],
        issue_fetcher: fetcher,
        blocked_by_hydrator: fn value -> {:ok, value} end,
        dispatch_batch_yield_ms: 0,
        runner: fn dispatched, _recipient, _opts ->
          send(parent, {:started, dispatched.id})
          :ok
        end
      )

    after_first = apply_next_task_result(pending)
    assert TrackerTasks.running?(after_first, {:dispatch, :batch_yield}), "a deep mailbox must yield, not end the batch"

    # The owner drains its mailbox while the yield task runs.
    for _ <- 1..100, do: receive(do: (:webhook_burst_3683 -> :ok))

    resumed = apply_next_task_result(after_first)
    dispatched = apply_next_task_result(resumed)

    receive_barrier({:started, "chain-eligible"})
    assert Map.has_key?(dispatched.running, eligible.id)
  end

  test "the outcome of an asynchronous chain is recorded when the chain ends, not when it starts" do
    parent = self()
    ready = %Issue{id: "chain-outcome", identifier: "repo#chain-outcome", title: "ready", state: "todo"}
    state = %State{snapshot_key: self(), max_concurrent_agents: 4, effective_concurrent_agents: 4, blocked_ticket_ids: MapSet.new()}

    pending =
      Dispatcher.dispatch_or_hold(state, [ready], fn -> :ready end,
        admission_probes_fun: idle_probes(),
        log_fun: &send(parent, {:outcome_log, &1}),
        issue_fetcher: fn _ -> {:ok, [ready]} end,
        blocked_by_hydrator: fn value -> {:ok, value} end,
        runner: fn dispatched, _recipient, _opts ->
          send(parent, {:started, dispatched.id})
          :ok
        end
      )

    assert pending.dispatch_selection_hold == nil
    refute_received {:outcome_log, _}

    dispatched = apply_next_task_result(pending)
    receive_barrier({:started, "chain-outcome"})
    assert dispatched.dispatch_selection_hold == nil
    refute_received {:outcome_log, _}
  end

  test "a batch that cannot drain names its stop reason instead of :unknown" do
    parent = self()
    ready = %Issue{id: "chain-backlog", identifier: "repo#chain-backlog", title: "ready", state: "todo"}
    state = %State{max_concurrent_agents: 4, effective_concurrent_agents: 4, blocked_ticket_ids: MapSet.new()}
    for _ <- 1..100, do: send(self(), :backlog_3683)

    held =
      Dispatcher.dispatch_or_hold(state, [ready], fn -> :ready end,
        admission_probes_fun: idle_probes(),
        log_fun: &send(parent, {:outcome_log, &1}),
        issue_fetcher: fn _ -> flunk("a deep mailbox must not start candidate validation") end
      )

    for _ <- 1..100, do: receive(do: (:backlog_3683 -> :ok))

    assert held.dispatch_selection_hold.reasons == [:orchestrator_backlog]
    assert_received {:outcome_log, log}
    assert log =~ "orchestrator_backlog"
    refute log =~ "unknown"
  end

  defp apply_next_task_result(state) do
    receive do
      {ref, result} when is_reference(ref) ->
        {:handled, next} = TrackerTasks.result(state, ref, result)
        next
    after
      5_000 -> flunk("expected a dispatch chain task result")
    end
  end

  defp idle_probes do
    fn ->
      %{
        memory_mb: :unavailable,
        memory_threshold_mb: nil,
        fd_sample: :unavailable,
        runnable: :unavailable,
        run_queue_threshold: nil,
        schedulers: 16,
        load: 0.0,
        load_threshold: 1.5,
        build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
        provider_backends: [],
        github_quota: :available,
        cpu_snapshot: :unavailable,
        target: nil
      }
    end
  end
end
