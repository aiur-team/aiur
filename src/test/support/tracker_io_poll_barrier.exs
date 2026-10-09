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

    :sys.replace_state(server, fn state ->
      if state.poll_cycles_completed > 0 do
        send(owner, {:poll_finished, token})
        state
      else
        # Signal after the real result callback; shared PubSub is not a completion barrier.
        {ref, job} = Enum.find(state.tracker_tasks, fn {_ref, job} -> job.key == :dispatch_poll end)

        %{state | tracker_tasks: Map.put(state.tracker_tasks, ref, %{job | apply: job.apply ++ [completed]})}
      end
    end)

    receive_barrier({:poll_finished, ^token})
    :sys.get_state(server)
  end
end
