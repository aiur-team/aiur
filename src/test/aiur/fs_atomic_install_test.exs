defmodule Aiur.FsAtomicInstallTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "separate VMs choose different atomic-write temporary files", %{tmp_dir: root} do
    target = Path.join(root, "broker")
    first = temporary_path(target)
    second = temporary_path(target)
    refute first == second
    assert File.read!(target) == "broker bytes"
  end

  defp temporary_path(target) do
    code = """
    [target] = System.argv()
    :erlang.trace_pattern({File, :rename, 2}, true, [])
    parent = self()
    worker = spawn_link(fn -> receive do :write -> :ok = Aiur.Fs.atomic_write(target, "broker bytes"); send(parent, :written) end end)
    :erlang.trace(worker, true, [:call])
    send(worker, :write)
    receive do
      {:trace, ^worker, :call, {File, :rename, [temporary, ^target]}} -> IO.puts(temporary)
    after
      5000 -> raise "atomic rename not observed"
    end
    receive do
      :written -> :ok
    after
      5000 -> raise "atomic write did not finish"
    end
    """

    source = Path.expand("../../lib/aiur/fs.ex", __DIR__)
    {output, 0} = System.cmd("elixir", ["-r", source, "-e", code, target], env: [{"ERL_FLAGS", "+S 1:1 +A 1"}], stderr_to_stdout: true)
    String.trim(output)
  end
end
