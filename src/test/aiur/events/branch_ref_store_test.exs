defmodule Aiur.Events.BranchRefStoreTest do
  use ExUnit.Case, async: false

  alias Aiur.Events.BranchRefStore

  test "reloads the latest validated refs before consumers start" do
    path = Path.join(System.tmp_dir!(), "branch-refs-#{System.unique_integer([:positive])}.json")
    ref = "refs/heads/aiur/99-dependency"
    sha = String.duplicate("a", 40)

    on_exit(fn -> File.rm(path) end)

    {:ok, first} = BranchRefStore.start_link(name: nil, path: path)
    assert :ok = BranchRefStore.record(ref, sha, first)
    GenServer.stop(first)

    {:ok, restarted} = BranchRefStore.start_link(name: nil, path: path)
    assert BranchRefStore.latest("99", restarted) == %{ref: ref, sha: sha}

    GenServer.stop(restarted)
  end

  test "retains a one-shot unblock until its exact ref is observed" do
    path = Path.join(System.tmp_dir!(), "branch-unblocks-#{System.unique_integer([:positive])}.json")
    ref = "refs/heads/aiur/99-dependency"
    sha = String.duplicate("b", 40)
    metadata = %{ref: ref, sha: sha}

    on_exit(fn -> File.rm(path) end)

    {:ok, first} = BranchRefStore.start_link(name: nil, path: path)
    assert :pending = BranchRefStore.register_unblock(ref, sha, first)
    GenServer.stop(first)

    {:ok, restarted} = BranchRefStore.start_link(name: nil, path: path)
    assert {:ok, ^metadata} = BranchRefStore.record_and_ready_unblock(ref, sha, restarted)
    GenServer.stop(restarted)

    {:ok, ready} = BranchRefStore.start_link(name: nil, path: path)
    assert BranchRefStore.ready_unblock("99", ready) == metadata
    assert :ok = BranchRefStore.acknowledge_unblock(ref, sha, ready)
    GenServer.stop(ready)

    {:ok, acknowledged} = BranchRefStore.start_link(name: nil, path: path)
    assert {:ok, nil} = BranchRefStore.record_and_ready_unblock(ref, sha, acknowledged)
    GenServer.stop(acknowledged)
  end

  test "default persistence survives a new launch log root" do
    root = Path.join(System.tmp_dir!(), "branch-state-#{System.unique_integer([:positive])}")
    state_dir = Path.join(root, "stable-instance-project")
    previous_log_file = Application.get_env(:aiur, :log_file)
    previous_state_dir = Application.get_env(:aiur, :decision_state_dir)
    ref = "refs/heads/aiur/99-dependency"
    sha = String.duplicate("c", 40)

    on_exit(fn ->
      restore_env(:log_file, previous_log_file)
      restore_env(:decision_state_dir, previous_state_dir)
      File.rm_rf(root)
    end)

    Application.put_env(:aiur, :decision_state_dir, state_dir)
    Application.put_env(:aiur, :log_file, Path.join(root, "launch-one/aiur.log"))

    {:ok, first} = BranchRefStore.start_link(name: nil)
    assert :ok = BranchRefStore.record(ref, sha, first)
    GenServer.stop(first)

    Application.put_env(:aiur, :log_file, Path.join(root, "launch-two/aiur.log"))
    {:ok, restarted} = BranchRefStore.start_link(name: nil)
    assert BranchRefStore.latest("99", restarted) == %{ref: ref, sha: sha}
    assert :ready = BranchRefStore.register_unblock(ref, sha, restarted)
    GenServer.stop(restarted)
  end

  test "resolved default persistence survives a new launch log root without an override" do
    root = Path.join(System.tmp_dir!(), "branch-default-state-#{System.unique_integer([:positive])}")
    previous_log_file = Application.get_env(:aiur, :log_file)
    previous_state_dir = Application.get_env(:aiur, :decision_state_dir)
    previous_instance_key = System.get_env("AIUR_INSTANCE_KEY")
    previous_bg_state_dir = System.get_env("AIUR_BG_STATE_DIR")
    ref = "refs/heads/aiur/99-dependency"
    sha = String.duplicate("e", 40)

    on_exit(fn ->
      restore_env(:log_file, previous_log_file)
      restore_env(:decision_state_dir, previous_state_dir)
      restore_system_env("AIUR_INSTANCE_KEY", previous_instance_key)
      restore_system_env("AIUR_BG_STATE_DIR", previous_bg_state_dir)
      File.rm_rf(root)
    end)

    Application.delete_env(:aiur, :decision_state_dir)
    System.put_env("AIUR_INSTANCE_KEY", "stable-instance")
    System.put_env("AIUR_BG_STATE_DIR", Path.join(root, "state"))
    Application.put_env(:aiur, :log_file, Path.join(root, "launch-one/aiur.log"))

    {:ok, first} = BranchRefStore.start_link(name: nil)
    assert :ok = BranchRefStore.record(ref, sha, first)
    GenServer.stop(first)

    Application.put_env(:aiur, :log_file, Path.join(root, "launch-two/aiur.log"))
    {:ok, restarted} = BranchRefStore.start_link(name: nil)
    assert BranchRefStore.latest("99", restarted) == %{ref: ref, sha: sha}
    GenServer.stop(restarted)
  end

  test "empty instance key fails closed instead of accepting state under launch log roots" do
    root = Path.join(System.tmp_dir!(), "branch-closed-state-#{System.unique_integer([:positive])}")
    previous_log_file = Application.get_env(:aiur, :log_file)
    previous_state_dir = Application.get_env(:aiur, :decision_state_dir)
    previous_instance_key = System.get_env("AIUR_INSTANCE_KEY")
    previous_bg_state_dir = System.get_env("AIUR_BG_STATE_DIR")
    previous_trap_exit = Process.flag(:trap_exit, true)
    launch_one = Path.join(root, "launch-one")
    launch_two = Path.join(root, "launch-two")

    on_exit(fn ->
      restore_env(:log_file, previous_log_file)
      restore_env(:decision_state_dir, previous_state_dir)
      restore_system_env("AIUR_INSTANCE_KEY", previous_instance_key)
      restore_system_env("AIUR_BG_STATE_DIR", previous_bg_state_dir)
      Process.flag(:trap_exit, previous_trap_exit)
      File.rm_rf(root)
    end)

    Application.delete_env(:aiur, :decision_state_dir)
    System.put_env("AIUR_INSTANCE_KEY", "")
    System.put_env("AIUR_BG_STATE_DIR", Path.join(root, "state"))
    Application.put_env(:aiur, :log_file, Path.join(launch_one, "aiur.log"))

    assert {:error, {:decision_state_dir_unavailable, :missing_instance_key}} =
             BranchRefStore.start_link(name: nil)

    Application.put_env(:aiur, :log_file, Path.join(launch_two, "aiur.log"))

    assert {:error, {:decision_state_dir_unavailable, :missing_instance_key}} =
             BranchRefStore.start_link(name: nil)

    refute File.exists?(Path.join(launch_one, "test-repo.branch_refs.json"))
    refute File.exists?(Path.join(launch_two, "test-repo.branch_refs.json"))
  end

  test "an identical record retries persistence after a transient write failure" do
    root = Path.join(System.tmp_dir!(), "branch-retry-#{System.unique_integer([:positive])}")
    blocker = Path.join(root, "not-a-directory")
    path = Path.join(blocker, "branch-refs.json")
    ref = "refs/heads/aiur/99-dependency"
    sha = String.duplicate("d", 40)

    File.mkdir_p!(root)
    File.write!(blocker, "blocks mkdir_p")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, store} = BranchRefStore.start_link(name: nil, path: path)
    assert :ok = BranchRefStore.record(ref, sha, store)
    assert BranchRefStore.latest("99", store) == %{ref: ref, sha: sha}

    File.rm!(blocker)
    assert :ok = BranchRefStore.record(ref, sha, store)
    GenServer.stop(store)

    {:ok, restarted} = BranchRefStore.start_link(name: nil, path: path)
    assert BranchRefStore.latest("99", restarted) == %{ref: ref, sha: sha}
    GenServer.stop(restarted)
  end

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
