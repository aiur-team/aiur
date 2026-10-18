defmodule Aiur.LandingWatch.RecoveryRuntimeTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch

  test "queued main recovery poll survives a crashed poll task" do
    parent = self()
    server = {:global, {__MODULE__, make_ref()}}

    {:ok, pid} =
      LandingWatch.start_link(
        name: server,
        interval_ms: 60_000,
        subscribe: false,
        observe_fun: fn opts ->
          case Keyword.get(opts, :main_ci_recovery_window) do
            nil ->
              send(parent, {:ordinary_poll_started, self()})

              receive do
                :stop -> {:ok, []}
              end

            window ->
              send(parent, {:recovery_poll_started, window})
              {:ok, []}
          end
        end,
        queue_reconcile_fun: fn _, _ -> :ok end
      )

    assert_receive {:ordinary_poll_started, poll_pid}, 1_000
    send(pid, {:event, %{topic: "system.main.ci.failed.resolved", red_since: 10, recovered_at: 20}})
    Process.exit(poll_pid, :kill)

    assert_receive {:recovery_poll_started, {10, 20}}, 1_000
    GenServer.stop(pid)
  end

  test "queued main recovery poll runs after the active poll completes" do
    parent = self()
    server = {:global, {__MODULE__, make_ref()}}

    {:ok, pid} =
      LandingWatch.start_link(
        name: server,
        interval_ms: 60_000,
        subscribe: false,
        observe_fun: fn opts ->
          case Keyword.get(opts, :main_ci_recovery_window) do
            nil ->
              send(parent, {:ordinary_poll_started, self()})

              receive do
                :finish -> {:ok, []}
              end

            window ->
              send(parent, {:recovery_poll_started, window})
              {:ok, []}
          end
        end,
        queue_reconcile_fun: fn _, _ -> :ok end
      )

    assert_receive {:ordinary_poll_started, poll_pid}, 1_000
    send(pid, {:event, %{topic: "system.main.ci.failed.resolved", red_since: 30, recovered_at: 40}})
    send(poll_pid, :finish)

    assert_receive {:recovery_poll_started, {30, 40}}, 1_000
    GenServer.stop(pid)
  end

  test "a recovery poll does not start a second ordinary poll timer chain" do
    parent = self()
    server = {:global, {__MODULE__, make_ref()}}
    {:ok, scheduled} = Agent.start_link(fn -> [] end)

    {:ok, pid} =
      LandingWatch.start_link(
        name: server,
        interval_ms: 60_000,
        subscribe: false,
        send_after_fun: fn _pid, message, _delay ->
          Agent.update(scheduled, &[message | &1])
        end,
        observe_fun: fn opts ->
          type = if Keyword.has_key?(opts, :main_ci_recovery_window), do: :recovery, else: :ordinary
          send(parent, {:poll_started, type, self()})

          receive do
            :finish -> {:ok, []}
          end
        end,
        queue_reconcile_fun: fn _, _ -> :ok end
      )

    assert_receive {:poll_started, :ordinary, first_poll}, 1_000
    assert Agent.get(scheduled, & &1) == [:poll]
    send(pid, {:event, %{topic: "system.main.ci.failed.resolved", red_since: 10, recovered_at: 20}})
    send(first_poll, :finish)
    assert_receive {:poll_started, :recovery, recovery_poll}, 1_000
    assert Agent.get(scheduled, & &1) == [:poll]
    send(recovery_poll, :finish)
    GenServer.stop(pid)
    Agent.stop(scheduled)
  end

  test "a crashed main recovery poll retries its window once" do
    server = {:global, {__MODULE__, make_ref()}}
    parent = self()

    {:ok, pid} =
      LandingWatch.start_link(
        name: server,
        interval_ms: 60_000,
        subscribe: false,
        send_after_fun: fn _pid, message, _delay -> send(parent, {:scheduled, message}) end,
        observe_fun: fn opts ->
          case Keyword.get(opts, :main_ci_recovery_window) do
            nil ->
              send(parent, {:ordinary_poll_started, self()})

              receive do
                :finish -> {:ok, []}
              end

            window ->
              send(parent, {:recovery_poll_attempt, self(), window})

              receive do
                :crash -> raise("recovery observer crashed")
                :succeed -> {:ok, []}
              end
          end
        end,
        queue_reconcile_fun: fn _, _ -> :ok end
      )

    assert_receive {:ordinary_poll_started, poll_pid}, 1_000
    send(pid, {:event, %{topic: "system.main.ci.failed.resolved", red_since: 50, recovered_at: 60}})
    send(poll_pid, :finish)

    assert_receive {:recovery_poll_attempt, first_attempt, {50, 60}}, 1_000
    send(first_attempt, :crash)
    assert_receive {:scheduled, {:poll_recovery, {50, 60}, 1}}, 1_000
    send(pid, :poll)
    assert_receive {:scheduled, :poll}, 1_000
    assert_receive {:ordinary_poll_started, interleaved_poll}, 1_000
    send(pid, {:poll_recovery, {50, 60}, 1})
    send(interleaved_poll, :finish)

    assert_receive {:recovery_poll_attempt, retry_attempt, {50, 60}}, 1_000
    # Force a second recovery event to interleave while the retry task is active.
    send(pid, {:event, %{topic: "system.main.ci.failed.resolved", red_since: 70, recovered_at: 80}})
    send(retry_attempt, :succeed)
    assert_receive {:recovery_poll_attempt, queued_attempt, {70, 80}}, 1_000
    send(queued_attempt, :succeed)
    GenServer.stop(pid)
  end
end
