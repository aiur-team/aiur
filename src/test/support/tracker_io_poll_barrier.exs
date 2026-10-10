defmodule Aiur.TrackerIoPollBarrier do
  @moduledoc false

  import Aiur.TestSupport, only: [receive_barrier: 1]
  import ExUnit.Assertions, only: [flunk: 1]

  # Waits for the server to finish a poll cycle, whatever stage the poll is in
  # (or not yet started): a sys debug hook sees every state the server commits,
  # so no tracker-task bookkeeping has to exist when the barrier is installed.
  #
  # Fails after `timeout` naming what it waited for and what the server showed
  # instead, so a poll that never completes is not a bare ExUnit timeout (#4207).
  @spec await_poll_finished(pid(), timeout()) :: map()
  def await_poll_finished(server, timeout \\ 30_000) do
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

    receive do
      {:poll_finished, ^token} -> :ok
    after
      timeout -> flunk("waited #{timeout} ms for #{inspect(server)} to complete a poll cycle (poll_cycles_completed > 0); saw #{seen(server)}")
    end

    :ok = :sys.remove(server, hook)
    :sys.get_state(server)
  end

  defp seen(server) do
    state = :sys.get_state(server)
    tasks = for {_ref, job} <- state.tracker_tasks, do: {job.key, job.task.pid}
    {:messages, mailbox} = Process.info(self(), :messages)
    "poll_cycles_completed=#{state.poll_cycles_completed}, tracker tasks #{inspect(tasks)}, test mailbox #{inspect(mailbox)}"
  catch
    :exit, reason -> "no answer from the server: #{inspect(reason)}"
  end

  @doc """
  Receives the held candidate poll that `server` itself owns.

  Tracker configuration is application-global, so any process that polls the
  tracker during the test announces itself with this test's token. Only a task
  the server tracks is one its shutdown reaps and whose release completes the
  server's poll cycle (#4207); another caller's signal is skipped.
  """
  @spec await_owned_poll(pid(), reference()) :: pid()
  def await_owned_poll(server, token) do
    receive_barrier({:poll_started, ^token, caller})
    # Asking a server that is itself held in the poll for its state would never return.
    if caller == server, do: flunk("the tracker is executing in the orchestrator handler")
    owned? = Enum.any?(:sys.get_state(server).tracker_tasks, fn {_ref, job} -> job.task.pid == caller end)
    if owned?, do: caller, else: await_owned_poll(server, token)
  end

  defp poll_finished?({:noreply, state}), do: state.poll_cycles_completed > 0
  defp poll_finished?({:out, _reply, _to, state}), do: state.poll_cycles_completed > 0
  defp poll_finished?(_event), do: false
end
