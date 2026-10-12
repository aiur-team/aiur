defmodule Aiur.BuildGateTestHolder do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1]
  import ExUnit.Assertions, only: [flunk: 1]

  # The one wait loop every test holder runs: it ends on release, when the lock
  # directory disappears, or when the owning process dies (#4183).
  @wait ~S"""
  printf 'ready\n'
  while [[ -d $AIUR_TEST_HOLDER_LOCK_DIR && ! -e $AIUR_TEST_HOLDER_RELEASE ]] && kill -0 "$AIUR_TEST_HOLDER_PARENT" 2>/dev/null; do sleep 0.5; done
  """

  def start!(bash, setup_script, args, lock_dir, release_path, parent_pid \\ System.pid()) do
    port =
      Port.open({:spawn_executable, String.to_charlist(bash)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", setup_script <> @wait | args],
        env: [
          {~c"AIUR_TEST_HOLDER_LOCK_DIR", String.to_charlist(lock_dir)},
          {~c"AIUR_TEST_HOLDER_RELEASE", String.to_charlist(release_path)},
          {~c"AIUR_TEST_HOLDER_PARENT", String.to_charlist(parent_pid)}
        ]
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
