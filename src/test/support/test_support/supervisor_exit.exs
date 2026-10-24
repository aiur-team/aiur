defmodule Aiur.TestSupport.SupervisorExit do
  @moduledoc false

  @reason_key {__MODULE__, :reason}
  @monitor_key {__MODULE__, :monitor}
  @pid_key {__MODULE__, :pid}
  @name_key {__MODULE__, :name}
  @notify_key {__MODULE__, :notify}

  def start_monitoring(name \\ Aiur.Supervisor, notify_pid \\ nil) do
    :persistent_term.put(@name_key, name)
    :persistent_term.put(@notify_key, notify_pid)
    :persistent_term.put(@reason_key, nil)
    monitor(Process.whereis(name))
  end

  def exit_reason, do: :persistent_term.get(@reason_key)

  def handle_info({:DOWN, ref, :process, _object, reason}, state) do
    if ref == :persistent_term.get(@monitor_key) do
      record_exit(reason, :persistent_term.get(@pid_key))
      notify({:supervisor_exit, reason})
    end

    {:noreply, state}
  end

  def handle_info(:refresh_supervisor_monitor, state) do
    name = :persistent_term.get(@name_key)

    case Process.whereis(name) do
      pid when is_pid(pid) ->
        if pid != :persistent_term.get(@pid_key) do
          monitor(pid)
          :persistent_term.put(@reason_key, nil)
          notify({:supervisor_monitor_restored, pid})
        end

      _ ->
        Process.send_after(self(), :refresh_supervisor_monitor, 250)
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp monitor(pid) when is_pid(pid) do
    :persistent_term.put(@pid_key, pid)
    :persistent_term.put(@monitor_key, Process.monitor(pid))
  end

  defp monitor(nil) do
    :persistent_term.put(@pid_key, nil)
    :persistent_term.put(@monitor_key, Process.monitor(:persistent_term.get(@name_key)))
  end

  defp record_exit(reason, pid) do
    :persistent_term.put(@reason_key, reason)
    Process.send_after(self(), :refresh_supervisor_monitor, 250)
    :persistent_term.put(@pid_key, pid)
  end

  defp notify(message) do
    case :persistent_term.get(@notify_key, nil) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end
end
