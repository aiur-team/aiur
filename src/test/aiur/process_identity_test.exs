defmodule Aiur.ProcessIdentityTest do
  use ExUnit.Case, async: true

  test "bounded kill fallback leaves no port messages in the caller mailbox" do
    {output, 0} = System.cmd("sh", ["-c", "echo $$"])
    dead_pid = output |> String.trim() |> String.to_integer()
    fake_proc_root = Path.join(Aiur.TestSupport.tmp_root!("process-identity-proc"), "missing-proc")
    key = {Aiur.ProcessIdentity, :proc_root}
    previous = Process.put(key, fake_proc_root)

    try do
      refute Aiur.ProcessIdentity.alive?(dead_pid)

      messages = Process.info(self(), :messages) |> elem(1)
      refute Enum.any?(messages, &match?({port, _} when is_port(port), &1))
    after
      if previous, do: Process.put(key, previous), else: Process.delete(key)
    end
  end
end
