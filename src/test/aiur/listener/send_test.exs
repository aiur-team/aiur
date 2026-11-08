defmodule Aiur.Listener.SendTest do
  use ExUnit.Case, async: false
  alias Aiur.{AgentChat, AgentQueueStore, Issue, Listener, Orchestrator}
  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator.{OperatorMessages, State}

  defmodule Target do
    @behaviour Aiur.Listener.DeliveryTarget
    @impl true
    def enqueue(target, text, opts) do
      send(self(), {:enqueue, target, text, opts})
      {:ok, 87}
    end

    @impl true
    def get_mode(_), do: {:error, :unsupported}
    @impl true
    def set_mode(_, _, _), do: {:error, :unsupported}
    @impl true
    def read_snapshot(_, _), do: {:error, :unsupported}
  end

  defmodule Server do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state, name: Aiur.Orchestrator)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    defdelegate handle_call(message, from, state), to: Aiur.Orchestrator
  end

  setup do
    previous = Application.fetch_env!(:aiur, :listener_delivery_target)

    on_exit(fn ->
      Application.put_env(:aiur, :listener_delivery_target, previous)
    end)

    :ok
  end

  test "AgentChat delegates once through registered target with listener default and origin" do
    Application.put_env(:aiur, :listener_delivery_target, Target)
    assert {:ok, 87} = AgentChat.send("42", "hello", message_id: "retry")
    assert_received {:enqueue, "42", "hello", opts}
    assert opts == [delivery_policy: :listener, origin: :agent_chat, message_id: "retry"]
    refute_received {:enqueue, _, _, _}
  end

  test "explicit policy and native correlation survive facade delegation" do
    Application.put_env(:aiur, :listener_delivery_target, Target)
    correlation = %{native_ref: "native-1"}
    assert {:ok, 87} = AgentChat.send("42", "hello", delivery_policy: :interrupt, origin: :voice_assistant, correlation: correlation)
    assert_received {:enqueue, "42", "hello", opts}
    assert opts[:delivery_policy] == :interrupt
    assert opts[:origin] == :voice_assistant
    assert opts[:correlation] == correlation
  end

  test "all conversation surfaces default to sync without interrupting" do
    pid = server()

    for origin <- [:agent_chat, :voice_assistant, :tui, :http, :internal] do
      assert {:ok, id} = Listener.send("42", "hello", origin: origin)
      item = AgentQueueStore.get(:sys.get_state(pid).queue_store, id)
      assert item.delivery.listener_mode_at_claim == :sync
      refute item.delivery.interrupt_requested
      assert item.origin == origin
    end
  end

  test "client_request_id deduplicates sends while explicit policy and native correlation survive" do
    pid = server()
    opts = [origin: :http, client_request_id: "one-action", delivery_policy: :interrupt, correlation: %{native_ref: "native-reply"}]
    assert {:ok, id} = Listener.send("42", "hello", opts)
    assert {:ok, ^id} = Listener.send("42", "hello", opts)
    assert [item] = AgentQueueStore.list_pending(:sys.get_state(pid).queue_store, "42")
    assert item.correlation == %{native_ref: "native-reply"}
    assert item.message_id == "one-action"
    assert item.delivery.interrupt_requested
  end

  test "HTTP copies authenticated device actor into the enqueued item" do
    pid = server()
    unless Process.whereis(AiurWeb.Endpoint), do: start_supervised!({AiurWeb.Endpoint, server: false})
    conn = Plug.Test.conn(:post, "/") |> Plug.Conn.assign(:auth_actor, {:device, "d1"})
    conn = AiurWeb.ObservabilityApiController.send_message(conn, %{"issue_identifier" => "42", "text" => "hello", "actor" => "device:spoof"})
    assert conn.status == 202
    assert [item] = AgentQueueStore.list_pending(:sys.get_state(pid).queue_store, "42")
    assert item.actor == "device:d1"
    assert item.origin == :http
    refute item.delivery.interrupt_requested
  end

  test "default dashboard send to a mid-turn codex agent waits for turn end and unavailable mode returns an error" do
    spec = Module.concat(["Aiur", "Listener", "Spec"])

    unless Code.ensure_loaded?(spec) do
      Code.compile_quoted(
        quote do
          defmodule unquote(spec) do
            @spec status() :: :ok
            def status, do: :ok
          end
        end
      )

      on_exit(fn ->
        :code.purge(spec)
        :code.delete(spec)
      end)
    end

    pid = server()
    :ok = ActiveTurns.put("42", "active-send")
    on_exit(fn -> ActiveTurns.mark_closed("42", "active-send", :test_cleanup) end)
    assert {:ok, id} = AgentChat.send("42", "next turn")
    state = :sys.get_state(pid)
    item = AgentQueueStore.get(state.queue_store, id)
    assert item.delivery.listener_mode_at_claim == :sync
    refute item.delivery.interrupt_requested
    assert {:reply, :empty, ^state} = OperatorMessages.claim_next_checkpoint_queue_item_call(state, "42")
    ActiveTurns.mark_closed("42", "active-send", :completed)
    assert {:reply, {:ok, claimed}, _} = OperatorMessages.claim_next_operator_queue_item_call(state, "42")
    assert claimed.id == id
    :sys.replace_state(pid, &put_in(&1.running["42"].session_execution.backend, "unknown"))
    assert {:error, :listener_mode_unavailable} = AgentChat.send("42", "unavailable")
  end

  test "listener core has no orchestration or AgentChat dependency" do
    root = Path.expand("../../../lib/aiur", __DIR__)

    for file <- [Path.join(root, "listener.ex") | Path.wildcard(Path.join(root, "listener/**/*.ex"))] do
      refute File.read!(file) =~ ~r/Aiur\.(Orchestrator|AgentChat)\b/, file
    end
  end

  defp server do
    dir = Aiur.TestSupport.tmp_root!("listener-send")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    Aiur.TestSupport.put_runtime_state_dir!(dir)
    original = Process.whereis(Orchestrator)
    if original, do: Process.unregister(Orchestrator)
    on_exit(fn -> if original && Process.alive?(original), do: Process.register(original, Orchestrator) end)
    entry = %{identifier: "42", issue: %Issue{id: "42", identifier: "42"}, session_execution: %{backend: "codex"}, control: %{status: :working, can_interrupt: true}}
    start_supervised!({Server, %State{running: %{"42" => entry}, queue_store: AgentQueueStore.new()}})
  end
end
