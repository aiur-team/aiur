defmodule Aiur.Opencode.Slot.ServeLifecycleTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.{Slot.ServeLifecycle, TokenRegistry}

  defmodule FailsThenServe do
    def start_link(_opts), do: Agent.start_link(fn -> :serve end)

    def await_ready(pid) do
      attempts = Process.get(:serve_attempts, 0) + 1
      Process.put(:serve_attempts, attempts)

      if attempts <= Process.get(:failures_before_success, 1) do
        Process.put(:failed_servers, [pid | Process.get(:failed_servers, [])])
        {:error, {:opencode_exit_status, 1}}
      else
        {:ok, "http://127.0.0.1:43210", nil}
      end
    end
  end

  defmodule AlwaysFailsServe do
    def start_link(_opts) do
      {:ok, pid} = Agent.start_link(fn -> :serve end)
      Process.put(:failed_servers, [pid | Process.get(:failed_servers, [])])
      {:ok, pid}
    end

    def await_ready(_pid), do: {:error, {:opencode_exit_status, 1}}
  end

  defmodule ExitsBeforeAwaitServe do
    def start_link(_opts) do
      attempts = Process.get(:early_exit_attempts, 0) + 1
      Process.put(:early_exit_attempts, attempts)

      if attempts == 1 do
        pid = spawn(fn -> :ok end)
        ref = Process.monitor(pid)
        assert_dead(ref, pid)
        {:ok, pid}
      else
        Agent.start_link(fn -> :serve end)
      end
    end

    def await_ready(pid) do
      if Process.get(:early_exit_attempts) == 1,
        do: GenServer.call(pid, :await_ready),
        else: {:ok, "http://127.0.0.1:43211", nil}
    end

    defp assert_dead(ref, pid) do
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1_000 -> raise "fake serve did not exit"
      end
    end
  end

  test "boot retries a transient serve exit so its slot can continue to attach-pane spawning" do
    root = Aiur.TestSupport.tmp_root!("aiur-slot-locked-serve")
    Process.put(:serve_attempts, 0)
    Process.put(:failed_servers, [])

    on_exit(fn ->
      Process.delete(:serve_attempts)
      Process.delete(:failed_servers)
      File.rm_rf(root)
    end)

    state = %{slot_index: 98, generation: 1, workspace_path: Path.join(root, "slot"), attached_identifiers: MapSet.new(["ticket-a"])}

    assert {:ok, server, "http://127.0.0.1:43210", token} =
             ServeLifecycle.boot(state, ["ticket-a", "ticket-b"], [], FailsThenServe)

    assert TokenRegistry.valid?(token, "ticket-a")
    refute TokenRegistry.valid?(token, "ticket-b")
    assert TokenRegistry.valid?(token, "_slot-98")
    assert Process.get(:serve_attempts) == 2
    assert [failed_server] = Process.get(:failed_servers)
    refute Process.alive?(failed_server)
    assert Process.alive?(server)
    Agent.stop(server)
    assert :ok = TokenRegistry.delete(token)
  end

  test "boot remains recoverable when the shared database locks twice" do
    root = Aiur.TestSupport.tmp_root!("aiur-slot-twice-locked-serve")
    Process.put(:serve_attempts, 0)
    Process.put(:failures_before_success, 2)
    Process.put(:failed_servers, [])

    on_exit(fn ->
      Process.delete(:serve_attempts)
      Process.delete(:failures_before_success)
      Process.delete(:failed_servers)
      File.rm_rf(root)
    end)

    state = %{slot_index: 97, generation: 1, workspace_path: Path.join(root, "slot")}

    assert {:ok, server, "http://127.0.0.1:43210", token} =
             ServeLifecycle.boot(state, [], [], FailsThenServe)

    assert Process.get(:serve_attempts) == 3
    assert length(Process.get(:failed_servers)) == 2
    assert Enum.all?(Process.get(:failed_servers), &(not Process.alive?(&1)))
    assert Process.alive?(server)
    Agent.stop(server)
    assert :ok = TokenRegistry.delete(token)
  end

  test "boot retries when serve exits before await_ready can register" do
    root = Aiur.TestSupport.tmp_root!("aiur-slot-serve-early-exit")
    Process.put(:early_exit_attempts, 0)

    on_exit(fn ->
      Process.delete(:early_exit_attempts)
      File.rm_rf(root)
    end)

    state = %{slot_index: 96, generation: 1, workspace_path: Path.join(root, "slot")}

    assert {:ok, server, "http://127.0.0.1:43211", token} =
             ServeLifecycle.boot(state, [], [], ExitsBeforeAwaitServe)

    assert Process.get(:early_exit_attempts) == 2
    assert Process.alive?(server)
    Agent.stop(server)
    assert :ok = TokenRegistry.delete(token)
  end

  test "boot stops after two retries and reaps all failed servers" do
    root = Aiur.TestSupport.tmp_root!("aiur-slot-persistent-serve-failure")
    Process.put(:failed_servers, [])

    on_exit(fn ->
      Process.delete(:failed_servers)
      TokenRegistry.delete_stale(99, 2)
      File.rm_rf(root)
    end)

    state = %{slot_index: 99, generation: 1, workspace_path: Path.join(root, "slot")}

    assert {:error, {:error, {:opencode_exit_status, 1}}} =
             ServeLifecycle.boot(state, [], [], AlwaysFailsServe)

    failed_servers = Process.get(:failed_servers)
    assert length(failed_servers) == 3
    assert Enum.all?(failed_servers, &(not Process.alive?(&1)))
  end

  # --- writers_for_base_url/2 ---

  test "writers_for_base_url returns only entries matching base_url" do
    entries = [
      %{base_url: "http://a:1234", session_id: "s1"},
      %{base_url: "http://b:1234", session_id: "s2"},
      %{base_url: "http://a:1234", session_id: "s3"}
    ]

    result = ServeLifecycle.writers_for_base_url(entries, "http://a:1234")
    assert length(result) == 2
    assert Enum.all?(result, fn e -> e.base_url == "http://a:1234" end)
  end

  test "writers_for_base_url returns empty when no match" do
    entries = [%{base_url: "http://x:1234"}]
    assert [] = ServeLifecycle.writers_for_base_url(entries, "http://y:1234")
  end

  # --- workspace_path_for/1 ---

  test "workspace_path_for returns path ending with opencode-slot-N" do
    path = ServeLifecycle.workspace_path_for(3)
    assert String.ends_with?(path, ".local/share/aiur/opencode-slot-3")
  end

  # --- maybe_run_session_gc/1 ---

  test "maybe_run_session_gc returns :ok for non-slot-1 state" do
    state = %{slot_index: 2, base_url: "http://x"}
    assert :ok = ServeLifecycle.maybe_run_session_gc(state)
  end

  test "maybe_run_session_gc returns :ok for slot-1 (fires background task)" do
    state = %{slot_index: 1, base_url: "http://127.0.0.1:1"}
    assert :ok = ServeLifecycle.maybe_run_session_gc(state)
  end

  # --- teardown_generation/1 ---

  test "teardown_generation with nil state fields returns :ok without external calls" do
    state = %{base_url: nil, server_pid: nil, pane_id: nil, token: nil}
    assert :ok = ServeLifecycle.teardown_generation(state)
  end

  test "teardown_generation with binary base_url and nil server/pane/token returns :ok" do
    # SessionWriterRegistry.all() returns [] when registry not running; reap is a no-op
    state = %{base_url: "http://127.0.0.1:1", server_pid: nil, pane_id: nil, token: nil}
    assert :ok = ServeLifecycle.teardown_generation(state)
  end

  test "teardown_generation stops a live server before returning" do
    {:ok, server_pid} = Agent.start_link(fn -> :running end)

    assert :ok =
             ServeLifecycle.teardown_generation(%{
               base_url: nil,
               server_pid: server_pid,
               pane_id: nil,
               token: nil
             })

    refute Process.alive?(server_pid)
  end

  # --- terminate_cleanup/1 ---

  test "terminate_cleanup with nil state fields returns :ok without external calls" do
    state = %{base_url: nil, server_pid: nil, pane_id: nil, token: nil}
    assert :ok = ServeLifecycle.terminate_cleanup(state)
  end

  test "terminate_cleanup with binary base_url and nil server/pane/token returns :ok" do
    # Same as above: reap_writers_for_base_url on empty registry is a safe no-op
    state = %{base_url: "http://127.0.0.1:1", server_pid: nil, pane_id: nil, token: nil}
    assert :ok = ServeLifecycle.terminate_cleanup(state)
  end

  test "terminate_cleanup tolerates stopping a live server" do
    {:ok, server_pid} = Agent.start_link(fn -> :running end)

    assert :ok =
             ServeLifecycle.terminate_cleanup(%{
               base_url: nil,
               server_pid: server_pid,
               pane_id: nil,
               token: nil
             })

    refute Process.alive?(server_pid)
  end
end
