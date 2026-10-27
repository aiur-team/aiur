defmodule AiurWeb.Build.IdleDaemonCompletionTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias AiurWeb.Build.Index

  # Future regression guard: deactivate clears the task, so stale completions
  # cannot reach daemon_result on an inactive index.
  test "last subscriber departure clears the in-flight daemon task and ignores its late result" do
    parent = self()
    counter = :atomics.new(1, [])
    block = %{state: "unknown", heartbeat_at: nil, observed_at: now()}

    server =
      start_supervised!(
        {Index,
         name: nil,
         idle_without_subscribers?: true,
         subscribe: fn -> :ok end,
         read: fn _, _, _ -> parts() end,
         timer: fn _, _, _ ->
           send(parent, :pack_refresh_scheduled)
           make_ref()
         end,
         daemon_timer: fn _, _, _ ->
           send(parent, :daemon_initialized)
           make_ref()
         end,
         daemon_read: fn _ ->
           if :atomics.add_get(counter, 1, 1) == 1 do
             block
           else
             send(parent, {:daemon_read_started, self()})

             receive do
               :release -> block
             end
           end
         end}
      )

    subscriber =
      spawn(fn ->
        :ok = Index.subscribe(server)
        send(parent, :subscribed)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :subscribed, 1000
    assert_receive :daemon_initialized, 1000
    assert {:ok, _window} = Index.window(server, "Etc/UTC")
    send(server, :daemon_tick)
    assert_receive {:daemon_read_started, worker}, 1000
    task_ref = :sys.get_state(server).daemon_task.ref
    worker_monitor = Process.monitor(worker)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1000
    inactive = :sys.get_state(server)
    refute inactive.active?
    assert inactive.daemon_task == nil
    send(server, {task_ref, block})
    after_completion = :sys.get_state(server)
    assert after_completion.timer == nil
    assert MapSet.size(after_completion.dirty) == 0
    refute_received :pack_refresh_scheduled
  end
end
