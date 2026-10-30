Code.require_file("../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.ExecutorHookDeliveryControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.{AgentQueue, AgentQueueStore, Orchestrator}
  alias Aiur.Conversation.TestSupport
  alias Aiur.Executor.{HookToken, Session}
  alias Aiur.Listener.{HookEnvelope, ModeStore, Receipt}
  alias Aiur.Orchestrator.OperatorMessages.{ExecutorHookClaims, PendingStore}

  # Only process lifecycle and fixture insertion are doubled; claims route through the production callbacks.
  defmodule Broker do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state, name: Orchestrator)
    def init(state), do: {:ok, state}
    def handle_call(:store, _from, state), do: {:reply, state.queue_store, state}

    def handle_call({:enqueue, target, text, opts}, _from, state) do
      {store, item} = AgentQueueStore.enqueue(state.queue_store, AgentQueue.operator_message(target, text, opts))
      {:reply, item.id, %{state | queue_store: store}}
    end

    def handle_call(message, from, state), do: Orchestrator.handle_call(message, from, state)
    def handle_cast(message, state), do: Orchestrator.handle_cast(message, state)
  end

  setup context do
    context = TestSupport.setup(context)
    Aiur.TestSupport.put_runtime_state_dir!(context.root)
    previous = Map.new([:executor_state_dir, :pending_operator_messages_store_path], &{&1, Application.fetch_env(:aiur, &1)})
    key = System.get_env("AIUR_INSTANCE_KEY")
    Application.put_env(:aiur, :executor_state_dir, Path.join(context.root, "executor"))
    Application.put_env(:aiur, :pending_operator_messages_store_path, Path.join(context.root, "pending.json"))
    System.put_env("AIUR_INSTANCE_KEY", "hook-delivery")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:aiur, key, value)
        {key, :error} -> Application.delete_env(:aiur, key)
      end)

      if key, do: System.put_env("AIUR_INSTANCE_KEY", key), else: System.delete_env("AIUR_INSTANCE_KEY")
    end)

    start_supervised!({Session, instance_key: "hook-delivery"})
    original = Process.whereis(Orchestrator)
    if original, do: Process.unregister(Orchestrator)

    on_exit(fn ->
      if original && Process.alive?(original) && is_nil(Process.whereis(Orchestrator)), do: Process.register(original, Orchestrator)
    end)

    broker = start_supervised!({Broker, %Orchestrator.State{queue_store: AgentQueueStore.new()}})
    assert :ok = HookToken.ensure()
    assert {:ok, token} = HookToken.read()
    assert {:ok, pending} = Session.attach(%{harness: "claude"})
    assert {:ok, binding} = Session.bind_provider_session(pending.binding_id, %{session_id: "session-http"})
    Map.merge(context, %{token: token, binding: binding, broker: broker})
  end

  test "Stop returns block envelope, persists harness queueing and does not duplicate", context do
    id = enqueue("executor", "please inspect the run")
    worker = enqueue("6503", "private worker message")
    response = request(context)
    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["application/json; charset=utf-8"]
    assert %{"decision" => "block", "reason" => reason} = Jason.decode!(response.resp_body)
    assert reason =~ "please inspect the run"
    refute reason =~ "private worker message"
    item = item(id)
    assert item.status == :delivered
    assert Receipt.from_snapshot(item).receipt == :harness_queued
    assert item.delivery.delivered_via == :hook
    assert item.delivery.hook_event == :stop
    assert item.delivery.binding_id == context.binding.binding_id
    assert item.delivery.generation == context.binding.generation
    assert is_binary(item.delivery.delivery_attempt_id)
    assert item(worker).status == :pending
    persisted = PendingStore.load()
    assert AgentQueueStore.get(persisted, id) == nil
    assert AgentQueueStore.get(persisted, worker).status == :pending
    assert request(context).status == 204
  end

  test "continuation, start, unknown event, subagent and malformed payload claim nothing", context do
    id = enqueue("executor", "waiting")

    for payload <- [payload("Stop", %{"stop_hook_active" => true}), payload("SessionStart"), payload("Other"), payload("PostToolUse", %{"agent_id" => "child"}), %{}] do
      response = request(context, payload)
      assert response.status == 204
      assert response.resp_body == ""
      assert item(id).status == :pending
    end
  end

  test "PostToolUse delivers steer but not sync; async stays pull-only", context do
    id = enqueue("executor", "waiting")
    assert request(context, payload("PostToolUse")).status == 204
    assert item(id).status == :pending
    assert {:ok, _} = ModeStore.put("executor", :steer, 0, %{actor: :human})
    assert request(context, payload("PostToolUse")).status == 200
    assert item(id).status == :delivered
    async = enqueue("executor", "held", listener_mode: :async)
    assert {:ok, _} = ModeStore.put("executor", :async, 1, %{actor: :human})
    pending = enqueue("executor", "new message")
    assert request(context).status == 204
    assert item(pending).status == :pending
    assert item(async).status == :pending
    assert {:ok, _} = ModeStore.put("executor", :sync, 2, %{actor: :human})
    response = request(context, payload("UserPromptSubmit"))
    assert response.status == 200
    assert Jason.decode!(response.resp_body)["hookSpecificOutput"]["hookEventName"] == "UserPromptSubmit"
    refute response.resp_body =~ "held"
    assert item(async).status == :pending
  end

  test "foreign session, harness, detached and absent binding receive nothing", context do
    id = enqueue("executor", "secret")
    assert request(context, payload("Stop", %{"session_id" => "foreign"})).status == 204
    assert request(context, payload(), harness: "codex").status == 204
    assert {:ok, _} = Session.detach(context.binding.binding_id, :test)
    assert request(context).status == 204
    stop_supervised!(Session)
    assert request(context).status == 204
    assert item(id).status == :pending
  end

  test "wrong, absent and duplicate tokens return 401; remote IPv4 and IPv6 return 403", context do
    id = enqueue("executor", "secret")

    for token <- [nil, "wrong"] do
      assert request(Map.put(context, :token, token)).status == 401
    end

    connection = build_conn(context, payload(), []) |> prepend_req_headers([{"authorization", "Bearer #{context.token}"}])
    assert route(connection).status == 401

    for ip <- [{192, 0, 2, 1}, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}] do
      assert request(context, payload(), remote_ip: ip).status == 403
    end

    assert item(id).status == :pending
  end

  test "IPv6 loopback delivery is available on a read-only dashboard", context do
    Aiur.TestSupport.start_owned_endpoint!()
    previous = AiurWeb.Endpoint.config(:dashboard_writable)
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, false)
    on_exit(fn -> Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, previous) end)
    id = enqueue("executor", "read-only dashboard")
    assert request(context, payload(), remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}).status == 200
    assert item(id).status == :delivered
  end

  test "batch preserves arrival order and claims at most the rendered count", context do
    ids = for n <- 1..51, do: enqueue("executor", "message #{n}")
    response = request(context)
    assert response.status == 200
    reason = Jason.decode!(response.resp_body)["reason"]
    assert reason =~ ~s(count="50")
    positions = for n <- 1..50, do: :binary.match(reason, "[aiur:delivery #{Enum.at(ids, n - 1)}]") |> elem(0)
    assert positions == Enum.sort(positions)
    assert Enum.all?(Enum.take(ids, 50), &(item(&1).status == :delivered))
    assert item(List.last(ids)).status == :pending
    assert request(context).status == 200
  end

  test "64 KiB frame truncates first message and leaves the next pending", context do
    id = enqueue("executor", String.duplicate("界", 30_000))
    next = enqueue("executor", "next")
    response = request(context)
    assert response.status == 200
    reason = Jason.decode!(response.resp_body)["reason"]
    assert String.valid?(reason)
    assert byte_size(reason) <= 65_536
    assert reason =~ "[truncated]"
    assert item(id).status == :delivered
    assert item(next).status == :pending
  end

  test "render failure and expired deadline leave items pending", context do
    id = enqueue("executor", "waiting")
    opts = options(context, render: fn _, _, _ -> raise "render failure" end)
    assert ExecutorHookClaims.claim_executor_hook_batch(context.binding.binding_id, :stop, opts) == :none
    assert item(id).status == :pending
    assert ExecutorHookClaims.claim_executor_hook_batch(context.binding.binding_id, :stop, options(context, deadline: System.monotonic_time(:millisecond) - 1)) == :none
    assert item(id).status == :pending
  end

  test "late queued call times out without claiming when broker resumes", context do
    id = enqueue("executor", "waiting")
    :sys.suspend(context.broker)

    try do
      assert ExecutorHookClaims.claim_executor_hook_batch(context.binding.binding_id, :stop, options(context, deadline: System.monotonic_time(:millisecond) + 10)) == :none
    after
      :sys.resume(context.broker)
    end

    assert item(id).status == :pending
  end

  test "timeout during rendering leaves the batch pending after late completion", context do
    id = enqueue("executor", "waiting")
    owner = self()

    render = fn harness, event, entries ->
      send(owner, {:rendering, self()})

      receive do
        :finish_render -> HookEnvelope.render(harness, event, entries)
      end
    end

    task = Task.async(fn -> ExecutorHookClaims.claim_executor_hook_batch(context.binding.binding_id, :stop, options(context, render: render)) end)
    receive_barrier({:rendering, renderer})
    assert Task.await(task, :infinity) == :none
    send(renderer, :finish_render)
    assert item(id).status == :pending
    assert item(id).provider_delivered_at == nil
  end

  test "response write failure restores only its attempt, including persisted messages", context do
    previous = enqueue("executor", "already emitted")
    assert request(context).status == 200
    id = enqueue("executor", "retry me")
    connection = build_conn(context, payload(), [])
    {adapter, state} = connection.adapter
    connection = %{connection | adapter: {__MODULE__.FailedAdapter, {adapter, state}}}
    error = assert_raise Plug.Conn.WrapperError, fn -> route(connection) end
    assert Exception.message(error.reason) == "HTTP write failed"
    assert item(id).status == :pending
    assert item(id).provider_delivered_at == nil
    assert item(previous).status == :delivered
    assert PendingStore.load().items[id].body.text == "retry me"
    assert request(context).status == 200
  end

  test "Codex uses the same envelope contract for its attached session", context do
    assert {:ok, pending} = Session.attach(%{harness: "codex", takeover?: true})
    assert {:ok, _} = Session.bind_provider_session(pending.binding_id, %{session_id: "codex-session"})
    id = enqueue("executor", "Codex instruction")
    response = request(context, payload("Stop", %{"session_id" => "codex-session"}), harness: "codex")
    assert response.status == 200
    assert Jason.decode!(response.resp_body)["reason"] =~ "Codex instruction"
    assert Receipt.from_snapshot(item(id)).receipt == :harness_queued
  end

  test "persistence failure cannot acknowledge a message", context do
    id = enqueue("executor", "keep pending")
    path = Application.fetch_env!(:aiur, :pending_operator_messages_store_path)
    File.mkdir_p!(path)
    assert request(context).status == 204
    assert item(id).status == :pending
    assert item(id).provider_delivered_at == nil
  end

  test "takeover generation rejects old claims and never replays delivered items", context do
    delivered = enqueue("executor", "already delivered")
    assert request(context).status == 200
    pending = enqueue("executor", "next binding")
    assert {:ok, next} = Session.attach(%{harness: "claude", takeover?: true})
    assert {:ok, _} = Session.bind_provider_session(next.binding_id, %{session_id: "new-session"})
    assert ExecutorHookClaims.claim_executor_hook_batch(context.binding.binding_id, :stop, options(context)) == :none
    assert item(pending).status == :pending
    assert request(context, payload("Stop", %{"session_id" => "new-session"})).status == 200
    assert item(delivered).delivery_attempts == 1
    assert item(pending).delivery.generation == next.generation
  end

  defmodule FailedAdapter do
    def send_resp(_, _, _, _), do: raise("HTTP write failed")
  end

  defp options(context, overrides \\ []) do
    Keyword.merge([deadline: System.monotonic_time(:millisecond) + 1_400, attempt: "test-attempt", session_id: "session-http", harness: "claude", generation: context.binding.generation], overrides)
  end

  defp enqueue(target, text, opts \\ []), do: GenServer.call(Orchestrator, {:enqueue, target, text, Keyword.put(opts, :persist_across_restart?, true)})
  defp item(id), do: GenServer.call(Orchestrator, :store) |> AgentQueueStore.get(id)
  defp payload(event \\ "Stop", extra \\ %{}), do: Map.merge(%{"hook_event_name" => event, "session_id" => "session-http"}, extra)
  defp request(context, payload \\ payload(), opts \\ []), do: build_conn(context, payload, opts) |> route()

  defp build_conn(context, payload, opts) do
    connection = conn(:post, "/api/v1/executor/hook/deliver?harness=#{Keyword.get(opts, :harness, "claude")}", payload)
    connection = %{connection | remote_ip: Keyword.get(opts, :remote_ip, {127, 0, 0, 1})}
    if context.token, do: put_req_header(connection, "authorization", "Bearer #{context.token}"), else: connection
  end

  defp route(connection), do: AiurWeb.Router.call(connection, AiurWeb.Router.init([]))
end
