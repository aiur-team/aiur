defmodule Aiur.TestSupport.SupervisorExit do
  @moduledoc false

  # Every observed exit, oldest first. A later restart must not erase one: the
  # suite reports leaks at its end, after test helpers restarted the app (#5886).
  @exits_key {__MODULE__, :exits}
  @monitor_key {__MODULE__, :monitor}
  @pid_key {__MODULE__, :pid}
  @name_key {__MODULE__, :name}
  @notify_key {__MODULE__, :notify}

  def start_monitoring do
    :persistent_term.put(@exits_key, [])
    start_monitoring(Aiur.Supervisor, nil)
  end

  def start_monitoring(name, notify_pid \\ nil) do
    :persistent_term.put(@name_key, name)
    :persistent_term.put(@notify_key, notify_pid)
    monitor(Process.whereis(name))
  end

  @doc "The most recent exit reason of the monitored supervisor, kept after it restarts."
  def exit_reason do
    name = :persistent_term.get(@name_key)

    case for({^name, reason, _last} <- :persistent_term.get(@exits_key, []), do: reason) do
      [] -> nil
      reasons -> List.last(reasons)
    end
  end

  def runtime_child_errors([]), do: []

  def runtime_child_errors(leaks) do
    name = :persistent_term.get(@name_key)
    exits = for {^name, reason, last} <- :persistent_term.get(@exits_key, []), do: "#{inspect(reason)} after #{last || "unknown"}"
    reason_note = if exits == [], do: "", else: " (#{inspect(name)} exits: #{Enum.join(exits, "; ")})"

    ["plain ExUnit tests left shared runtime children down: #{Enum.join(leaks, ", ")}#{reason_note}"]
  end

  def handle_info({:DOWN, ref, :process, _object, reason}, last_finished) do
    if ref == :persistent_term.get(@monitor_key) do
      record_exit(reason, last_finished, :persistent_term.get(@pid_key))
      notify({:supervisor_exit, reason})
    end

    {:noreply, last_finished}
  end

  def handle_info(:refresh_supervisor_monitor, state) do
    name = :persistent_term.get(@name_key)

    case Process.whereis(name) do
      pid when is_pid(pid) ->
        if pid != :persistent_term.get(@pid_key) do
          monitor(pid)
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

  defp record_exit(reason, last_finished, pid) do
    exit = {:persistent_term.get(@name_key), reason, last_finished}
    :persistent_term.put(@exits_key, :persistent_term.get(@exits_key, []) ++ [exit])
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
