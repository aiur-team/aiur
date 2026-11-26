defmodule Aiur.Experiments.Evaluation do
  @moduledoc false

  @spec start(map(), GenServer.from(), (-> term()), (term() -> term())) :: tuple()
  def start(%{evaluation: nil} = state, from, prepare, finish) do
    owner = self()
    token = make_ref()
    {:ok, pid} = Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> send(owner, {:evaluation_finished, token, protected(prepare)}) end)
    monitor = Process.monitor(pid)
    timer = Process.send_after(owner, {:evaluation_timeout, token}, state.evaluation_timeout_ms)
    job = %{pid: pid, token: token, monitor: monitor, timer: timer, from: from, finish: finish}
    {:noreply, %{state | evaluation: job}}
  end

  def start(state, _from, _prepare, _finish), do: {:reply, {:error, :evaluation_busy}, state}

  @spec handle(term(), map()) :: tuple()
  def handle({:evaluation_finished, token, result}, %{evaluation: %{token: token}} = state), do: complete(state, result)

  def handle({:evaluation_timeout, token}, %{evaluation: %{token: token} = job} = state) do
    Process.exit(job.pid, :kill)
    complete(state, {:error, :evaluation_timeout})
  end

  def handle({:DOWN, monitor, :process, _pid, reason}, %{evaluation: %{monitor: monitor}} = state),
    do: complete(state, {:error, {:evaluation_failed, reason}})

  def handle(_message, state), do: {:noreply, state}

  @spec stop(map()) :: :ok
  def stop(%{evaluation: nil}), do: :ok

  def stop(%{evaluation: job}) do
    Process.exit(job.pid, :kill)
    :ok
  end

  defp complete(%{evaluation: job} = state, result) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
    GenServer.reply(job.from, job.finish.(result))
    {:noreply, %{state | evaluation: nil}}
  end

  defp protected(prepare) do
    prepare.()
  rescue
    error -> {:error, {:evaluation_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:evaluation_failed, {kind, reason}}}
  end
end
