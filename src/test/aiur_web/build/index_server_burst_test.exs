defmodule AiurWeb.Build.IndexServerBurstTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  import Aiur.TestSupport.BuildHome.IndexParts
  alias AiurWeb.Build.Index

  setup do
    parent = self()

    opts = [
      name: nil,
      broadcast: fn _changes -> :ok end,
      subscribe: fn -> :ok end,
      read: fn dirty, _previous, _opts ->
        send(parent, {:read_started, self(), dirty})

        receive do
          {:return, parts} -> parts
          :crash -> exit(:killed_read)
        end
      end,
      timer: fn pid, message, ms ->
        send(parent, {:timer, pid, message, ms})
        make_ref()
      end,
      daemon_timer: fn _pid, _, _ -> make_ref() end,
      daemon_read: fn _ -> %{state: "live", heartbeat_at: 1, observed_at: 2} end,
      clock: &now/0
    ]

    pid = start_supervised!({Index, opts})
    receive_barrier({:read_started, worker, :all})
    :erlang.trace(pid, true, [:receive])
    send(worker, {:return, parts()})
    result_barrier(pid)
    %{pid: pid}
  end

  test "a burst of queued signals is handled in one call and the next read covers every merged part", %{pid: pid} do
    :sys.suspend(pid)
    for n <- 1..5_000, do: send(pid, {:running_changed, n})
    for _ <- 1..50, do: send(pid, :fleet_changed)
    :erlang.trace(pid, true, [:call])
    :erlang.trace_pattern({Index, :handle_info, 2}, true, [:local])
    on_exit(fn -> :erlang.trace_pattern({Index, :handle_info, 2}, false, [:local]) end)
    :sys.resume(pid)
    :sys.get_state(pid)

    assert {:message_queue_len, 0} = Process.info(pid, :message_queue_len)
    assert signal_handler_calls(0) == 1

    send(pid, :flush)
    receive_barrier({:read_started, worker, dirty})
    assert MapSet.subset?(MapSet.new([:now, :planned, :capacity]), dirty)
    send(worker, {:return, parts()})
    result_barrier(pid)
  end

  defp signal_handler_calls(count) do
    receive do
      {:trace, _, :call, {Index, :handle_info, [{:running_changed, _}, _]}} -> signal_handler_calls(count + 1)
    after
      0 -> count
    end
  end

  defp result_barrier(pid) do
    receive_barrier({:trace, ^pid, :receive, {_ref, %{settings: _settings}}})
    :sys.get_state(pid)
  end
end
