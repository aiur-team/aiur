defmodule Aiur.Identity.MachineTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.Identity.Machine

  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-machine-#{System.unique_integer([:positive])}")
    keys = [{Machine, :boot_result}, {Machine, :boot_context}]
    previous = Enum.map(keys, &{&1, :persistent_term.get(&1, :not_loaded)})

    on_exit(fn ->
      File.chmod(dir, 0o700)
      File.rm_rf!(dir)
      for {key, value} <- previous, do: :persistent_term.put(key, value)
    end)

    %{dir: dir, path: Path.join(dir, "identity.json")}
  end

  test "current reports not_loaded before initialization" do
    :persistent_term.erase({Machine, :boot_result})
    assert Machine.current() == :not_loaded
  end

  test "creates random identity with private directory and file", %{dir: dir, path: path} do
    assert {:ok, identity} = Machine.ensure(dir: dir, hostname_fun: fn -> {:ok, ~c"workstation.example"} end, now: ~U[2026-10-06 16:00:00Z])
    assert identity.machine_id =~ ~r/^[a-z2-7]{26}$/
    assert identity.machine_label == "workstation"
    assert identity.created_at == "2026-10-06T16:00:00Z"
    assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Jason.decode!(File.read!(path))["machine_id"] == identity.machine_id
    assert Machine.current() == {:ok, identity}
  end

  test "second ensure does not rewrite or generate an identity", %{dir: dir, path: path} do
    assert {:ok, identity} = Machine.ensure(dir: dir)
    File.touch!(path, {{2001, 1, 1}, {0, 0, 0}})
    before = File.stat!(path)
    bytes = File.read!(path)
    assert {:ok, ^identity} = Machine.ensure(dir: dir, random_fun: fn _ -> flunk("regenerated") end)
    assert File.read!(path) == bytes
    assert File.stat!(path).mtime == before.mtime
    assert File.stat!(path).inode == before.inode
  end

  test "corrupt file is unreadable and left untouched", %{dir: dir, path: path} do
    File.mkdir_p!(dir)
    File.write!(path, "{broken")
    assert {:degraded, :identity_unreadable, _reason} = Machine.ensure(dir: dir, random_fun: fn _ -> flunk("attempted regeneration") end)
    assert File.read!(path) == "{broken"
  end

  test "wrong schema and malformed ids are unreadable", %{dir: dir, path: path} do
    assert {:ok, _identity} = Machine.ensure(dir: dir)
    valid = Jason.decode!(File.read!(path))

    for invalid <- [Map.put(valid, "schema_version", 2), Map.put(valid, "machine_id", "host-identifier"), %{}, []] do
      bytes = Jason.encode!(invalid)
      File.write!(path, bytes)
      assert {:degraded, :identity_unreadable, _reason} = Machine.ensure(dir: dir)
      assert File.read!(path) == bytes
    end
  end

  test "unknown fields survive reads without a rewrite", %{dir: dir, path: path} do
    assert {:ok, identity} = Machine.ensure(dir: dir)
    bytes = path |> File.read!() |> Jason.decode!() |> Map.put("machine_key_public", "future-data") |> Jason.encode!()
    File.write!(path, bytes)
    assert {:ok, ^identity} = Machine.ensure(dir: dir)
    assert File.read!(path) == bytes
  end

  test "eight concurrent first boots return the winner even after all saw absence", %{dir: dir} do
    parent = self()

    tasks =
      for n <- 1..8 do
        Task.async(fn ->
          Machine.ensure(
            dir: dir,
            random_fun: fn 16 ->
              send(parent, {:ready, self()})
              receive_barrier(:create)
              <<n::128>>
            end
          )
        end)
      end

    for _ <- tasks, do: receive_barrier({:ready, _pid})
    # All callers saw absence; read each result before releasing the next
    # contender so rename-based clobbering cannot hide in scheduling.
    identities =
      Enum.map(tasks, fn task ->
        send(task.pid, :create)
        assert {:ok, identity} = Task.await(task)
        identity.machine_id
      end)

    assert length(Enum.uniq(identities)) == 1
    assert File.ls!(dir) == ["identity.json"]
  end

  test "uncreatable directory degrades without raising", %{dir: dir} do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o500)
    assert {:degraded, :identity_uncreatable, :eacces} = Machine.ensure(dir: Path.join(dir, "machine"))
    File.chmod!(dir, 0o700)
  end

  test "unexpected creation failure is cached and boot safe", %{dir: dir} do
    assert {:degraded, :identity_uncreatable, %RuntimeError{message: "entropy failure"}} =
             Machine.ensure(dir: dir, random_fun: fn _ -> raise "entropy failure" end)

    assert {:degraded, :identity_uncreatable, %RuntimeError{}} = Machine.current()
  end

  test "degraded attention names the directory and emits once", %{dir: dir, path: path} do
    File.mkdir_p!(dir)
    File.write!(path, "broken")
    assert {:degraded, :identity_unreadable, _reason} = Machine.ensure(dir: dir)
    parent = self()
    emit = fn name, opts -> send(parent, {:alert, name, opts}) end
    assert :ok = Machine.announce_degraded(emit_fun: emit)
    assert {:degraded, :identity_unreadable, _reason} = Machine.ensure(dir: dir)
    assert :ok = Machine.announce_degraded(emit_fun: emit)
    assert_received {:alert, "system.identity.unreadable", opts}
    assert opts[:needs_attention]
    assert opts[:message] =~ dir
    refute_received {:alert, _name, _opts}
  end

  test "creation attention uses the uncreatable cause", %{dir: dir} do
    Machine.ensure(dir: dir, random_fun: fn _ -> raise "entropy failure" end)
    parent = self()
    Machine.announce_degraded(emit_fun: fn name, opts -> send(parent, {:alert, name, opts}) end)
    assert_received {:alert, "system.identity.uncreatable", opts}
    assert opts[:needs_attention]
    assert opts[:message] =~ dir
  end

  test "healthy identity emits no attention", %{dir: dir} do
    assert {:ok, _identity} = Machine.ensure(dir: dir)
    parent = self()
    assert :ok = Machine.announce_degraded(emit_fun: fn name, opts -> send(parent, {:alert, name, opts}) end)
    refute_received {:alert, _name, _opts}
  end

  test "hostname controls are stripped and unicode label stays within 63 bytes", %{dir: dir} do
    host = "\n" <> String.duplicate("é", 40) <> ".example"
    assert {:ok, identity} = Machine.ensure(dir: dir, hostname_fun: fn -> {:ok, host} end)
    assert identity.machine_label == String.duplicate("é", 31)
    assert String.valid?(identity.machine_label)
  end

  test "unavailable hostname still creates a random identity", %{dir: dir} do
    assert {:ok, identity} = Machine.ensure(dir: dir, hostname_fun: fn -> {:error, :hostname_unavailable} end)
    assert identity.machine_label == "aiur"
  end
end
