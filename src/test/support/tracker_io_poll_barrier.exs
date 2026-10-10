defmodule Aiur.TrackerIoPollBarrier do
  @moduledoc false

  import Aiur.TestSupport, only: [receive_barrier: 1]

  # Waits for the server to finish a poll cycle, whatever stage the poll is in
  # (or not yet started): a sys debug hook sees every state the server commits,
  # so no tracker-task bookkeeping has to exist when the barrier is installed.
  @spec await_poll_finished(pid()) :: map()
  def await_poll_finished(server) do
    owner = self()
    token = make_ref()

    hook = fn :armed, event, _proc_state ->
      if poll_finished?(event) do
        send(owner, {:poll_finished, token})
        :done
      else
        :armed
      end
    end

    :ok = :sys.install(server, {hook, :armed})
    # A cycle that completed before the hook was installed never reaches it.
    if :sys.get_state(server).poll_cycles_completed > 0, do: send(owner, {:poll_finished, token})
    receive_barrier({:poll_finished, ^token})
    :ok = :sys.remove(server, hook)
    :sys.get_state(server)
  end

  defp poll_finished?({:noreply, state}), do: state.poll_cycles_completed > 0
  defp poll_finished?({:out, _reply, _to, state}), do: state.poll_cycles_completed > 0
  defp poll_finished?(_event), do: false
end
