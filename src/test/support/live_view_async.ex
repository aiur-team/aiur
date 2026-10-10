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
end
