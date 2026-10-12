defmodule Aiur.DeliveryEntryPointsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Phoenix.ConnTest

  alias Aiur.{AgentChat, AgentControlCLI, AgentQueueStore, DecisionAnswer, DecisionDispatch, DecisionRevision, DecisionRevisionDispatch, DecisionValidation, Issue}
  alias Aiur.Opencode.ChatCompletions.OperatorDispatch
  alias Aiur.Orchestrator.{OperatorMessages, State}
  alias AiurWeb.{DashboardLive, Endpoint, StreamdeckChannel}

  @endpoint Endpoint
  @moduletag :r7_characterization
  # Sender fixtures stay together to serialize shared Endpoint and Orchestrator state.
  # Regression guards: these pin sender choices already present on main.
  @identifier "MT-R7"

  defmodule RecordingOrchestrator do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    @impl true
    def init(owner), do: {:ok, owner}
    @impl true
    def handle_call({:send_operator_message, target, payload}, _from, owner) do
      send(owner, {:wire, target, payload})
      {:reply, {:ok, 1}, owner}
    end
  end

  setup do
    unless Process.whereis(Endpoint), do: start_supervised!({Endpoint, server: false})
    previous = Application.get_env(:aiur, Endpoint, [])
    config = Keyword.merge(previous, dashboard_writable: true, orchestrator: Aiur.Orchestrator)
    Application.put_env(:aiur, Endpoint, config)
    Endpoint.config_change([{Endpoint, config}], [])

    on_exit(fn ->
      Application.put_env(:aiur, Endpoint, previous)
      if Process.whereis(Endpoint), do: Endpoint.config_change([{Endpoint, previous}], [])
    end)

    :ok
  end

  test "AgentChat.send defaults to interrupt with queue_next fallback" do
    record_orchestrator()
    assert {:ok, 1} = AgentChat.send(@identifier, "x")
    assert_received {:wire, @identifier, payload}
    assert payload == %{kind: :text, body: "x", delivery_policy: :interrupt, fallback: :queue_next, turn_id: nil, message_id: nil}
  end

  test "TUI chat pane requests auto" do
    record_orchestrator()
    assert {:ok, 1} = OperatorDispatch.send_operator(@identifier, "x", "turn-r7")
    assert_received {:wire, @identifier, payload}
    assert payload == %{kind: :text, body: "x", delivery_policy: :auto, fallback: :queue_next, turn_id: "turn-r7", message_id: nil}
  end

  test "dashboard drawer passes only message_id so AgentChat governs policy" do
    record_chat_opts()

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, writable: true, agent_log_modal: %{issue_identifier: @identifier, writable_target?: true}, drafts: %{}, pending_message_ids: %{}, chat_errors: %{}}
    }

    assert {:noreply, _} = DashboardLive.handle_event("send-operator-message", %{"message" => "x"}, socket)
    assert_received {:chat, @identifier, "x", [message_id: "dashboard-" <> suffix]}
    assert byte_size(suffix) == 16
  end

  test "Stream Deck passes only message_id so AgentChat governs policy" do
    record_chat_opts()
    socket = %Phoenix.Socket{assigns: %{streamdeck_authenticated: true}}
    assert {:reply, {:ok, %{"request_id" => 1}}, _} = StreamdeckChannel.handle_in("say", %{"identifier" => @identifier, "text" => "x", "message_id" => "press-r7"}, socket)
    assert_received {:chat, @identifier, "x", [message_id: "press-r7"]}
  end

  test "aiur message passes only message_id so AgentChat governs policy" do
    owner = self()
    put_app_env(:agent_control_cli_status_fun, fn -> [%{issue_id: @identifier, identifier: @identifier, status: :working}] end)

    put_app_env(:agent_control_cli_message_fun, fn target, text, opts ->
      send(owner, {:chat, target, text, opts})
      {:error, {:outcome_unknown, %{message_id: Keyword.fetch!(opts, :message_id), item_id: nil}}}
    end)

    assert capture_io(fn -> AgentControlCLI.message(@identifier, "x", "cli-r7") end) =~ "outcome unknown"
    assert_received {:chat, @identifier, "x", [message_id: "cli-r7"]}
  end

  test "HTTP messages endpoint omits policy and retains the checkpoint default" do
    record_orchestrator()

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1")
      |> Plug.Conn.put_req_header("x-aiur-request", "1")

    assert %{"request_id" => 1} = conn |> post("/api/v1/#{@identifier}/messages", %{text: "x"}) |> json_response(202)
    assert_received {:wire, @identifier, payload}
    assert payload == %{kind: :text, body: "x"}

    state = %State{queue_store: AgentQueueStore.new(), running: %{@identifier => %{identifier: @identifier, control: %{can_interrupt: true, immediate_delivery: false}}}}
    assert {:reply, {:ok, item_id}, updated} = OperatorMessages.send_operator_message_call(state, @identifier, payload)
    [item] = AgentQueueStore.list_pending(updated.queue_store, @identifier)
    assert item.id == item_id
    assert item.delivery == %{priority: :next, durability: :durable, consume_at: :safe_checkpoint, interrupt_requested: false, immediate: false, fallback: nil}
  end

  test "Decision answers and revisions request interrupt with queue_next fallback" do
    decision = answered_decision()

    sender = fn _server, target, payload ->
      send(self(), {:decision, target, payload})
      {:ok, %{status: :accepted}}
    end

    assert {:ok, %{status: :accepted}} = DecisionDispatch.dispatch(decision, attempt_id: "answer-r7", send_fun: sender)
    assert_received {:decision, @identifier, answer}
    assert {answer.delivery_policy, answer.fallback} == {:interrupt, :queue_next}
    assert answer.action_id == decision.answer.action_id

    revision = %DecisionRevision{
      decision_id: decision.decision_id,
      recorded_at: DateTime.utc_now(),
      content_hash: "r7-revision",
      action_id: "revision-r7",
      prior_action_id: decision.answer.action_id,
      decision_version: decision.version,
      sequence: 1,
      reason: "New evidence",
      answer: decision.answer
    }

    revised = %{decision | revisions: [revision]}

    assert {:ok, %{status: :accepted}} =
             DecisionRevisionDispatch.dispatch(revised,
               attempt_id: "revision-r7",
               send_fun: sender,
               issue_fetcher: fn _ -> {:ok, []} end,
               terminal_states: MapSet.new(["done"]),
               revalidate_fun: fn %Issue{} = issue, _, _ -> {:ok, %Issue{issue | identifier: @identifier, state: "in-progress"}} end
             )

    assert_received {:decision, @identifier, corrective}
    assert {corrective.delivery_policy, corrective.fallback} == {:interrupt, :queue_next}
    assert corrective.action_id == revision.action_id
  end

  defp answered_decision do
    {:ok, decision} = DecisionValidation.normalize(%{"question" => "Continue?", "blocking" => true}, ticket: %{identifier: @identifier}, source: %{agent_id: "r7", session_id: "r7"})

    {:ok, answer} =
      DecisionAnswer.normalize(%{"idempotency_key" => "answer-r7", "expected_version" => decision.version, "custom_response" => "Proceed"},
        decision_id: decision.decision_id,
        decision_version: decision.version,
        actor: %{kind: :operator, id: "r7"}
      )

    %{decision | answer: answer, decision_status: :decided, delivery_status: :pending}
  end

  defp record_chat_opts do
    owner = self()

    config =
      Application.get_env(:aiur, Endpoint, [])
      |> Keyword.put(:agent_chat_send_fun, fn target, text, opts ->
        send(owner, {:chat, target, text, opts})
        {:ok, 1}
      end)

    Application.put_env(:aiur, Endpoint, config)
    Endpoint.config_change([{Endpoint, config}], [])
  end

  defp put_app_env(key, value) do
    previous = Application.fetch_env(:aiur, key)
    Application.put_env(:aiur, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:aiur, key, old)
        :error -> Application.delete_env(:aiur, key)
      end
    end)
  end

  defp record_orchestrator do
    name = Aiur.Orchestrator
    original = Process.whereis(name)
    if is_pid(original), do: Process.unregister(name)
    {:ok, fake} = RecordingOrchestrator.start_link(self())
    Process.unlink(fake)
    Process.register(fake, name)

    on_exit(fn ->
      if Process.alive?(fake), do: GenServer.stop(fake)
      if is_pid(original) and Process.alive?(original), do: Process.register(original, name)
    end)
  end
end
