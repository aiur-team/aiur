defmodule Aiur.TrackerIoPollBarrier do
  @moduledoc false

  import Aiur.TestSupport, only: [receive_barrier: 1]

  @spec await_poll_finished(pid()) :: map()
  def await_poll_finished(server) do
    owner = self()
    token = make_ref()

    completed = fn current, _result ->
      send(owner, {:poll_finished, token})
      current
    end

    :sys.replace_state(server, &observe_completion(&1, owner, token, completed))
    receive_barrier({:poll_finished, ^token})
    :sys.get_state(server)
  end

  @doc """
  Receives the held candidate poll that `server` itself owns.

  Tracker configuration is application-global, so any process that polls the
  tracker during the test announces itself with this test's token. Only a task
  the server tracks is one its shutdown reaps; another caller's signal is skipped.
  """
  @spec await_owned_poll(pid(), reference()) :: pid()
  def await_owned_poll(server, token) do
    receive_barrier({:poll_started, ^token, caller})
    owned? = Enum.any?(:sys.get_state(server).tracker_tasks, fn {_ref, job} -> job.task.pid == caller end)
    if owned?, do: caller, else: await_owned_poll(server, token)
  end

  defp observe_completion(state, owner, token, completed) do
    if state.poll_cycles_completed > 0 do
      send(owner, {:poll_finished, token})
      state
    else
      # Signal after the real result callback; shared PubSub is not a completion barrier.
      {ref, job} = Enum.find(state.tracker_tasks, fn {_ref, job} -> job.key == :dispatch_poll end)
      %{state | tracker_tasks: Map.put(state.tracker_tasks, ref, %{job | apply: job.apply ++ [completed]})}
    end
  end
end
