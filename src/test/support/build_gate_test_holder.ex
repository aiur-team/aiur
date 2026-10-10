defmodule Aiur.BuildGateTestHolder do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1]
  import ExUnit.Assertions, only: [flunk: 1]

  def start!(bash, script, args, release_path) do
    port =
      Port.open({:spawn_executable, String.to_charlist(bash)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", script | args]
      ])

    pid = holder_pid(port)
    identity = if is_integer(pid), do: Aiur.ProcessTree.process_identity(pid), else: :unknown

    on_exit(fn ->
      File.touch(release_path)

      receive do
        {^port, {:exit_status, _status}} -> :ok
      after
        1_000 ->
          if is_integer(pid) and match?({:ok, _}, identity), do: Aiur.ProcessTree.reap_process(pid, elem(identity, 1))
          if Port.info(port), do: Port.close(port)
      end
    end)

    receive do
      {^port, {:data, "ready\n"}} -> :ok
    after
      2_000 -> flunk("build-gate test holder did not become ready")
    end

    port
  end

  defp holder_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end
end
