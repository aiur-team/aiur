defmodule Aiur.MainWatchRuntimeTest do
  use Aiur.TestSupport
  alias Aiur.MainWatch

  test "missing and dead watchers are not running" do
    assert %{watcher: :not_running, status: :unknown} = MainWatch.state(:missing_main_watch)
    pid = spawn(fn -> :ok end)
    monitor = Process.monitor(pid)
    receive_barrier({:DOWN, ^monitor, :process, ^pid, _})
    assert %{watcher: :not_running, status: :unknown} = MainWatch.state(pid)
  end

  test "an unresponsive live watcher is unavailable rather than not running" do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(pid, :stop) end)
    assert %{watcher: :unavailable, status: :unknown, unavailable: true} = MainWatch.state(pid)
    assert Process.alive?(pid)
  end
end
