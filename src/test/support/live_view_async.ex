defmodule Aiur.TestSupport.LiveViewAsync do
  @moduledoc "Task-completion barrier bounded by ExUnit's test timeout, not scheduler latency."

  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Phoenix.LiveView.Channel
  alias Phoenix.LiveViewTest

  def render_when_complete(view) do
    # Use the same task list as render_async/2 without its 100ms deadline.
    {:ok, pids} = Channel.async_pids(view.pid)
    refs = Enum.map(pids, &Process.monitor/1)

    for ref <- refs do
      receive_barrier({:DOWN, ^ref, :process, _pid, _reason})
    end

    LiveViewTest.render(view)
  end

  def render_after_refresh(view) do
    relays = :sys.get_state(view.pid).socket.private.lifecycle.handle_info |> Enum.map(& &1.id) |> Enum.filter(&is_pid/1)
    deadline = System.monotonic_time(:millisecond) + 5_000
    for relay <- relays, do: await_refresh(relay, deadline)
    render_when_complete(view)
  end

  defp await_refresh(relay, deadline) do
    state = :sys.get_state(relay)

    if state.waiting? or map_size(state.pending) > 0 do
      if System.monotonic_time(:millisecond) >= deadline, do: raise("refresh relay did not settle")
      Process.sleep(20)
      await_refresh(relay, deadline)
    end
  end
end
