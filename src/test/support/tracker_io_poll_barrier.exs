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

  @doc """
  Receives the held timeline read made by `server`'s own dispatch validation of `issue_id`.

  The tracker stand-in is application-global, so any process that revalidates
  an issue during the test announces a read with this test's token. Releasing
  such a caller leaves the dispatch's own read held forever (#4009), so only
  the server's dispatch task is returned; another caller's signal is skipped.
  """
  @spec await_dispatch_timeline_read(pid(), String.t(), reference()) :: pid()
  def await_dispatch_timeline_read(server, issue_id, token) do
    receive_barrier({:timeline_read_started, ^token, reader})
    # Asking a server that is itself held in the read for its state would never return.
    if reader == server, do: raise(ExUnit.AssertionError, message: "dispatch authorization read the timeline in the orchestrator")
    owned? = Enum.any?(:sys.get_state(server).tracker_tasks, fn {_ref, job} -> job.key == {:dispatch, issue_id} and job.task.pid == reader end)
    if owned?, do: reader, else: await_dispatch_timeline_read(server, issue_id, token)
  end
end
