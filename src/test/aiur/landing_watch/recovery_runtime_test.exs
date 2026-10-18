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

  test "a crashed main recovery poll retries its window" do
    parent = self()
    server = {:global, {__MODULE__, make_ref()}}
    {:ok, attempts} = Agent.start_link(fn -> %{ordinary: 0, recovery: 0} end)

    {:ok, pid} =
      LandingWatch.start_link(
        name: server,
        interval_ms: 10,
        subscribe: false,
        observe_fun: fn opts ->
          case Keyword.get(opts, :main_ci_recovery_window) do
            nil ->
              if Agent.get_and_update(attempts, fn counts -> {counts.ordinary, %{counts | ordinary: counts.ordinary + 1}} end) == 0 do
                send(parent, {:ordinary_poll_started, self()})

                receive do
                  :finish -> {:ok, []}
                end
              else
                {:ok, []}
              end

            window ->
              attempt =
                Agent.get_and_update(attempts, fn counts ->
                  next = counts.recovery + 1
                  {next, %{counts | recovery: next}}
                end)

              send(parent, {:recovery_poll_attempt, attempt, window})
              if attempt == 1, do: raise("recovery observer crashed")
              {:ok, []}
          end
        end,
        queue_reconcile_fun: fn _, _ -> :ok end
      )

    assert_receive {:ordinary_poll_started, poll_pid}, 1_000
    send(pid, {:event, %{topic: "system.main.ci.failed.resolved", red_since: 50, recovered_at: 60}})
    send(poll_pid, :finish)

    assert_receive {:recovery_poll_attempt, 1, {50, 60}}, 1_000
    assert_receive {:recovery_poll_attempt, 2, {50, 60}}, 1_000
    GenServer.stop(pid)
    Agent.stop(attempts)
  end
end
