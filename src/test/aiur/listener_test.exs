defmodule Aiur.ListenerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Aiur.{AgentQueueStore, Listener, Orchestrator, TrackerIdentity}
  alias Aiur.Listener.ModeStore
  alias Aiur.Orchestrator.{ListenerModes, State}

  defmodule Server do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state, name: Aiur.Orchestrator)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    defdelegate handle_call(message, from, state), to: Aiur.Orchestrator
  end

  setup do
    original = Process.whereis(Orchestrator)
    if original, do: Process.unregister(Orchestrator)
    on_exit(fn -> if original && Process.alive?(original), do: Process.register(original, Orchestrator) end)
    dir = Aiur.TestSupport.tmp_root!("listener-control")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    Aiur.TestSupport.put_runtime_state_dir!(dir)
    entry = %{identifier: "42", session_execution: %{backend: "codex"}}
    state = %State{running: %{"id" => entry}, queue_store: AgentQueueStore.new()}
    pid = start_supervised!({Server, state})
    %{pid: pid, state: state, dir: dir}
  end

  test "get returns running harness projection and default record" do
    assert {:ok, view} = Listener.get_mode("42")
    assert %{requested: :sync, effective: :sync, version: 0, actor: :default, harness_source: :session, effective_reason: nil} = view
    assert view.support.sync.status == :proven
  end

  test "set persists version and actor, audits result, and preserves queue state", %{pid: pid, state: state} do
    log =
      capture_log(fn ->
        assert {:ok, %{requested: :async, effective: :sync, effective_reason: :pull_tool_unavailable, version: 1, actor: :executor}} =
                 Listener.set_mode("42", :async, expected_version: 0, actor: :executor)
      end)

    assert log =~ "listener_mode_set issue=42 requested=async effective=:sync version=1 actor=executor"
    assert %{requested: :async, version: 1, actor: :executor} = ModeStore.get("42")
    assert :sys.get_state(pid) == state
    assert {:ok, %{requested: :async, version: 1}} = Listener.get_mode("42")
  end

  test "concurrent writers yield one winner and one conflict with winning view" do
    results = [:async, :steer] |> Enum.map(fn mode -> Task.async(fn -> Listener.set_mode("42", mode, expected_version: 0) end) end) |> Enum.map(&Task.await/1)
    assert [winner] = for({:ok, view} <- results, do: view)
    assert [{:error, {:mode_conflict, ^winner}}] = Enum.filter(results, &match?({:error, _}, &1))
    assert {:ok, ^winner} = Listener.get_mode("42")
  end

  test "non-running tickets persist requested mode and report nil not_running" do
    assert {:ok, %{requested: :steer, effective: nil, effective_reason: :not_running, version: 1}} = Listener.set_mode("stopped", :steer, expected_version: 0)
    assert {:ok, %{requested: :steer, effective: nil, effective_reason: :not_running, version: 1}} = Listener.get_mode("stopped")
  end

  test "same-key retry returns original record without version bump" do
    opts = [expected_version: 0, idempotency_key: "retry", actor: :system]
    assert {:ok, first} = Listener.set_mode("42", :steer, opts)
    assert {:ok, ^first} = Listener.set_mode("42", :steer, opts)
    assert first.version == 1
    assert ModeStore.get("42").version == 1
  end

  test "invalid modes and metadata are rejected without writing" do
    assert {:error, :invalid_mode} = Listener.set_mode("42", :invalid, expected_version: 0)
    assert {:error, :invalid_expected_version} = Listener.set_mode("42", :sync, [])
    assert {:error, :invalid_expected_version} = Listener.set_mode("42", :sync, expected_version: -1)
    assert {:error, :invalid_actor} = Listener.set_mode("42", :sync, expected_version: 0, actor: :other)
    assert {:error, :invalid_idempotency_key} = Listener.set_mode("42", :sync, expected_version: 0, idempotency_key: 3)

    for target <- [nil, "", %TrackerIdentity{}] do
      assert {:error, :invalid_target} = Listener.get_mode(target)
      assert {:error, :invalid_target} = Listener.set_mode(target, :sync, expected_version: 0)
    end

    refute File.exists?(ModeStore.path_for("42"))
  end

  test "dead orchestrator returns unavailable", %{pid: pid} do
    Process.unregister(Orchestrator)
    assert {:error, :unavailable} = Listener.get_mode("42")
    assert {:error, :unavailable} = Listener.set_mode("42", :sync, expected_version: 0)
    Process.register(pid, Orchestrator)
  end

  test "timeout reports unknown outcome and keyed retry observes eventual write", %{pid: pid} do
    previous = Application.get_env(:aiur, :operator_message_call_timeout_ms)
    Application.put_env(:aiur, :operator_message_call_timeout_ms, 1)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :operator_message_call_timeout_ms, previous), else: Application.delete_env(:aiur, :operator_message_call_timeout_ms)
    end)

    :ok = :sys.suspend(pid)
    opts = [expected_version: 0, idempotency_key: "timed-out"]

    try do
      assert {:error, {:outcome_unknown, %{idempotency_key: "timed-out"}}} = Listener.set_mode("42", :async, opts)
    after
      :sys.resume(pid)
    end

    :sys.get_state(pid)
    Application.put_env(:aiur, :operator_message_call_timeout_ms, 30_000)
    assert {:ok, %{requested: :async, version: 1}} = Listener.set_mode("42", :async, opts)
  end

  test "identity lookup preserves ambiguity and allows a ticket without runner", %{state: state} do
    identity = %TrackerIdentity{status: :joinable, kind: :github, owner: "org", repository: "repo", provider_id: "I_42", identifier: "42", reason: nil}
    entry = Map.put(state.running["id"], :tracker_identity, identity)
    unique = %{state | running: %{"one" => entry}}
    assert {:reply, {:ok, %{effective: :sync}}, ^unique} = ListenerModes.get_mode(unique, identity)
    ambiguous = %{state | running: %{"one" => entry, "two" => entry}}
    assert {:reply, {:error, :ambiguous_identifier}, ^ambiguous} = ListenerModes.get_mode(ambiguous, identity)
    assert {:reply, {:error, :ambiguous_identifier}, ^ambiguous} = ListenerModes.set_mode(ambiguous, identity, :async, expected_version: 0)
    other = %{identity | provider_id: "I_other"}
    assert {:reply, {:error, :ambiguous_identifier}, ^unique} = ListenerModes.get_mode(unique, other)
    assert {:reply, {:error, :ambiguous_identifier}, ^unique} = ListenerModes.set_mode(unique, other, :async, expected_version: 0)
    assert ModeStore.get("42").version == 0
    stopped = %{state | running: %{}}
    assert {:reply, {:ok, %{effective: nil, effective_reason: :not_running, requested: :async}}, ^stopped} = ListenerModes.set_mode(stopped, identity, :async, expected_version: 0)
  end

  test "write failure retains previous record", %{dir: dir} do
    assert {:ok, first} = Listener.set_mode("42", :steer, expected_version: 0)
    File.chmod!(Path.join(dir, "listen-modes"), 0o500)

    try do
      assert {:error, {:write_failed, _}} = Listener.set_mode("42", :async, expected_version: 1)
      assert {:ok, ^first} = Listener.get_mode("42")
    after
      File.chmod!(Path.join(dir, "listen-modes"), 0o700)
    end
  end

  test "regression guard: control capabilities retain exact key set", %{state: state} do
    keys = Aiur.Orchestrator.OperatorMessages.Capabilities.issue_control_capabilities(state, "42") |> Map.keys() |> Enum.sort()
    assert keys == Enum.sort([:accepts_operator_messages, :accepted_delivery_policies, :can_interrupt, :immediate_delivery, :safe_checkpoints, :status, :unit_control, :pending_control, :queue_depth])
  end
end
