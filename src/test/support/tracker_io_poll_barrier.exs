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

  defp poll_finished?({:noreply, state}), do: state.poll_cycles_completed > 0
  defp poll_finished?({:out, _reply, _to, state}), do: state.poll_cycles_completed > 0
  defp poll_finished?(_event), do: false
end
