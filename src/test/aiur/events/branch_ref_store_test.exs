defmodule Aiur.Events.BranchRefStoreTest do
  use ExUnit.Case, async: false

  alias Aiur.Events.BranchRefStore
  alias Aiur.Orchestrator.EventTopics
  alias Aiur.Orchestrator.State

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

  test "a matching final unblock stays durable until routing acknowledges it" do
    path = Path.join(System.tmp_dir!(), "branch-ready-crash-#{System.unique_integer([:positive])}.json")
    ref = "refs/heads/aiur/99-dependency"
    sha = String.duplicate("c", 40)
    metadata = %{ref: ref, sha: sha}

    on_exit(fn -> File.rm(path) end)

    {:ok, first} = BranchRefStore.start_link(name: nil, path: path)
    assert :ok = BranchRefStore.record(ref, sha, first)
    assert :ready = BranchRefStore.register_unblock(ref, sha, first)
    assert BranchRefStore.ready_unblock("99", first) == metadata
    GenServer.stop(first)

    {:ok, restarted} = BranchRefStore.start_link(name: nil, path: path)
    assert BranchRefStore.ready_unblock("99", restarted) == metadata
    assert :ok = BranchRefStore.acknowledge_unblock(ref, sha, restarted)
    GenServer.stop(restarted)

    {:ok, acknowledged} = BranchRefStore.start_link(name: nil, path: path)
    assert BranchRefStore.ready_unblock("99", acknowledged) == nil
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

  test "a write failure is not accepted without a second caller" do
    root = Path.join(System.tmp_dir!(), "branch-retry-#{System.unique_integer([:positive])}")
    blocker = Path.join(root, "not-a-directory")
    path = Path.join(blocker, "branch-refs.json")
    ref = "refs/heads/aiur/99-dependency"
    sha = String.duplicate("d", 40)

    File.mkdir_p!(root)
    File.mkdir_p!(blocker)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, store} = BranchRefStore.start_link(name: nil, path: path)
    File.rm_rf!(blocker)
    File.write!(blocker, "blocks mkdir_p")

    assert :error = BranchRefStore.record(ref, sha, store)
    assert BranchRefStore.latest("99", store) == nil

    File.rm!(blocker)
    File.mkdir_p!(blocker)
    assert_eventually(fn -> BranchRefStore.latest("99", store) == %{ref: ref, sha: sha} end)
    GenServer.stop(store)

    {:ok, restarted} = BranchRefStore.start_link(name: nil, path: path)
    assert BranchRefStore.latest("99", restarted) == %{ref: ref, sha: sha}
    GenServer.stop(restarted)
  end

  test "failed branch and unblock writes compose into one durable retry" do
    root = Path.join(System.tmp_dir!(), "branch-unblock-retry-#{System.unique_integer([:positive])}")
    blocker = Path.join(root, "not-a-directory")
    path = Path.join(blocker, "branch-refs.json")
    ref = "refs/heads/aiur/99-dependency"
    sha = String.duplicate("e", 40)
    metadata = %{ref: ref, sha: sha}

    File.mkdir_p!(root)
    File.mkdir_p!(blocker)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, store} = BranchRefStore.start_link(name: nil, path: path)
    File.rm_rf!(blocker)
    File.write!(blocker, "blocks mkdir_p")

    assert :error = BranchRefStore.record(ref, sha, store)
    assert :error = BranchRefStore.register_unblock(ref, sha, store)
    assert BranchRefStore.latest("99", store) == nil
    assert BranchRefStore.ready_unblock("99", store) == nil

    File.rm!(blocker)
    File.mkdir_p!(blocker)

    assert_eventually(fn ->
      BranchRefStore.latest("99", store) == metadata and
        BranchRefStore.ready_unblock("99", store) == metadata
    end)

    GenServer.stop(store)

    {:ok, restarted} = BranchRefStore.start_link(name: nil, path: path)
    assert BranchRefStore.latest("99", restarted) == metadata
    assert BranchRefStore.ready_unblock("99", restarted) == metadata
    GenServer.stop(restarted)
  end

  test "branch-push routing autonomously preserves a write that fails once" do
    root = Path.join(System.tmp_dir!(), "branch-route-retry-#{System.unique_integer([:positive])}")
    blocker = Path.join(root, "not-a-directory")
    path = Path.join(blocker, "branch-refs.json")
    ref = "refs/heads/aiur/99-dependency"
    sha = String.duplicate("f", 40)
    original_path = :sys.get_state(BranchRefStore).path

    File.mkdir_p!(root)
    File.write!(blocker, "blocks mkdir_p")
    :ok = BranchRefStore.reset()
    :sys.replace_state(BranchRefStore, &Map.put(&1, :path, path))

    on_exit(fn ->
      File.rm_rf(root)
      :sys.replace_state(BranchRefStore, &Map.put(&1, :path, original_path))
      :ok = BranchRefStore.reset()
    end)

    state = %State{running: %{}}

    assert EventTopics.route(state, %{topic: "ticket.99.branch.push", ref: ref, sha: sha}) == state
    assert BranchRefStore.latest("99") == nil

    File.rm!(blocker)
    File.mkdir_p!(blocker)

    :ok = BranchRefStore.await_settled()
    assert BranchRefStore.latest("99") == %{ref: ref, sha: sha}

    {:ok, restarted} = BranchRefStore.start_link(name: nil, path: path)
    assert BranchRefStore.latest("99", restarted) == %{ref: ref, sha: sha}
    GenServer.stop(restarted)
  end

  test "existing unreadable state fails closed" do
    path = Path.join(System.tmp_dir!(), "branch-unreadable-#{System.unique_integer([:positive])}")
    previous_trap_exit = Process.flag(:trap_exit, true)

    File.mkdir_p!(path)

    on_exit(fn ->
      Process.flag(:trap_exit, previous_trap_exit)
      File.rm_rf(path)
    end)

    assert {:error, {:state_load_failed, _reason}} = BranchRefStore.start_link(name: nil, path: path)
  end

  test "existing corrupt state fails closed" do
    path = Path.join(System.tmp_dir!(), "branch-corrupt-#{System.unique_integer([:positive])}.json")
    previous_trap_exit = Process.flag(:trap_exit, true)

    File.write!(path, "{not-json")

    on_exit(fn ->
      Process.flag(:trap_exit, previous_trap_exit)
      File.rm(path)
    end)

    assert {:error, {:state_load_failed, _reason}} = BranchRefStore.start_link(name: nil, path: path)
  end

  test "existing structurally invalid state fails closed" do
    path = Path.join(System.tmp_dir!(), "branch-invalid-#{System.unique_integer([:positive])}.json")
    previous_trap_exit = Process.flag(:trap_exit, true)

    File.write!(path, Jason.encode!(%{refs: []}))

    on_exit(fn ->
      Process.flag(:trap_exit, previous_trap_exit)
      File.rm(path)
    end)

    assert {:error, {:state_load_failed, {:invalid_document, :invalid_fields}}} =
             BranchRefStore.start_link(name: nil, path: path)
  end

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end
end
