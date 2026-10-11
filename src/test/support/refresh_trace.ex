defmodule Aiur.TestSupport.RefreshTrace do
  @moduledoc """
  Counts the dashboard refreshes a function broadcasts from its own process.

  The refresh topic is VM-global and its messages carry no sender, so a
  subscriber cannot tell its own broadcast from a stray one. Call tracing can.
  """

  import Aiur.TestSupport, only: [receive_barrier: 1]

  def count(fun) when is_function(fun, 0) do
    parent = self()

    pid =
      spawn_link(fn ->
        receive_barrier(:go)
        fun.()
        send(parent, {:ran, self()})
        receive_barrier(:stop)
      end)

    # `refresh/0` reaches `refresh/1` through a local call, hence `:local`.
    :erlang.trace_pattern({Aiur.Signal, :refresh, 1}, true, [:local])
    :erlang.trace(pid, true, [:call])
    send(pid, :go)
    receive_barrier({:ran, ^pid})
    ref = :erlang.trace_delivered(pid)
    receive_barrier({:trace_delivered, ^pid, ^ref})
    send(pid, :stop)
    :erlang.trace_pattern({Aiur.Signal, :refresh, 1}, false, [:local])
    drain(pid, 0)
  end

  defp drain(pid, count) do
    receive do
      {:trace, ^pid, :call, {Aiur.Signal, :refresh, _args}} -> drain(pid, count + 1)
    after
      0 -> count
    end
  end
end
