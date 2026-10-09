defmodule Aiur.Stacking.GitCommandTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.{ProcessIdentity, ProcessTree}
  alias Aiur.Stacking.GitCommand
  alias Aiur.Workspace.{HostLock, Ownership}

  test "git children cannot read inherited daemon secrets" do
    workspace = Aiur.TestSupport.tmp_root!("restack-secrets")
    File.mkdir_p!(workspace)
    names = ["GITHUB_TOKEN", "GITHUB_APP_RESTACK_TEST", "OPENAI_API_KEY", "RELEASE_COOKIE"]
    previous = Map.new(names, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, fn {name, value} -> if value, do: System.put_env(name, value), else: System.delete_env(name) end) end)
    Enum.each(names, &System.put_env(&1, "restack-test"))
    command = "!" <> Enum.map_join(names, " && ", &"test -z \"${#{&1}:-}\"")
    assert {_output, 0} = GitCommand.run(workspace, ["-c", "alias.assertclean=#{command}", "assertclean"])
  end

  test "a failed OS spawn releases ownership without a provider hold" do
    ticket = "restack-spawn-fail-#{System.unique_integer([:positive])}"
    assert {:ok, lease} = Ownership.claim(ticket)
    assert {"git command unavailable", 127} = GitCommand.run(System.tmp_dir!(), [nil], lease)
    assert {:ok, %{phase: :released}} = Ownership.release_and_wait(lease)
    assert Ownership.current(ticket) == :none
  end

  test "cancelled git retains the workspace lock until its process group drains" do
    workspace = Aiur.TestSupport.tmp_root!("restack-cancel")
    File.mkdir_p!(workspace)
    ticket = "restack-cancel-#{System.unique_integer([:positive])}"
    parent = self()
    marker = Path.join(workspace, "running")

    worker =
      spawn(fn ->
        {:ok, lease} =
          Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
            process_identity_fun: fn pid ->
              send(parent, {:tracked, pid})
              ProcessIdentity.resolve(pid)
            end,
            reap_fun: fn pid, identity ->
              send(parent, {:reaping, self(), pid})
              receive do: (:drain -> ProcessTree.reap_process_group(pid, identity))
            end
          )

        {:ok, lock} = HostLock.acquire(workspace, ticket)
        :ok = HostLock.handoff_to_ownership(lock, lease)
        send(parent, {:claimed, lease})
        result = GitCommand.run(workspace, ["-c", "alias.restackwait=!echo ready > #{Aiur.Shell.escape(marker)}; sleep 30", "restackwait"], lease)
        send(parent, {:finished, result})
      end)

    receive_barrier({:claimed, lease})
    monitor = Process.monitor(lease.guardian)
    receive_barrier({:tracked, pid})
    await_marker(marker, 100)
    Process.exit(worker, :kill)
    assert_receive {:reaping, reaper, ^pid}, 2_000
    assert {:ok, _holder} = HostLock.holder(workspace)
    assert {:error, {:workspace_owned, _}} = Ownership.claim(ticket)
    send(reaper, :drain)
    receive_barrier({:DOWN, ^monitor, :process, _guardian, :normal})
    assert HostLock.holder(workspace) == :none
    refute ProcessTree.process_group_alive?(pid)
  end

  defp await_marker(path, attempts) do
    if File.exists?(path) do
      :ok
    else
      assert attempts > 0, "git did not start"
      Process.sleep(10)
      await_marker(path, attempts - 1)
    end
  end
end
