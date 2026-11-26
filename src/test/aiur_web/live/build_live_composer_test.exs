defmodule AiurWeb.BuildLiveComposerTest do
  # The poll delays are app env, which is global.
  use Aiur.TestSupport.BuildHome.ProtocolCase, async: false
  alias Aiur.TestSupport.{EndpointStubs, LiveViewAsync}
  alias AiurWeb.OperatorControlCenter.{AgentLogModal, OperatorSend}

  defmodule Source do
    def prepare(ref, opts) do
      running = Agent.get(opts[:control], &Map.get(&1, :running, [%{identifier: ref.id}]))
      entry = Enum.find(running, &(&1.identifier == ref.id))
      {:ok, Map.merge(ref, %{handle: "h:" <> ref.id, running: entry, fleet: %{fleet: %{running: running}}})}
    end

    def tail(_ref, _cursor, _opts), do: {:ok, %{state: :live, entries: [], before: nil, last: nil, more?: false, live?: true, observed_at: nil}}
    def page(_ref, _cursor, _opts), do: {:ok, %{entries: [], before: nil, more?: false}}
    def subscribe(_ref, _opts), do: :ok
    def unsubscribe(_ref, _opts), do: :ok
  end

  defmodule ConfiguredVoice do
    def configured?, do: true
  end

  defmodule UnconfiguredVoice do
    def configured?, do: false
  end

  setup do
    previous = Application.get_env(:aiur, :build_conversation_source)
    previous_delays = Application.get_env(:aiur, :build_send_status_delays_ms)
    previous_voice_provider = Application.fetch_env(:aiur, :voice_provider)
    control = start_supervised!({Agent, fn -> %{} end})
    Application.put_env(:aiur, :build_conversation_source, {Source, [control: control]})
    Application.put_env(:aiur, :build_send_status_delays_ms, [0, 0, 0])
    EndpointStubs.put(dashboard_writable: true)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :build_conversation_source, previous), else: Application.delete_env(:aiur, :build_conversation_source)
      if previous_delays, do: Application.put_env(:aiur, :build_send_status_delays_ms, previous_delays), else: Application.delete_env(:aiur, :build_send_status_delays_ms)

      case previous_voice_provider do
        {:ok, provider} -> Application.put_env(:aiur, :voice_provider, provider)
        :error -> Application.delete_env(:aiur, :voice_provider)
      end
    end)

    %{control: control}
  end

  defp stub_send(replies) do
    test_pid = self()
    {:ok, agent} = Agent.start_link(fn -> replies end)

    EndpointStubs.put(
      agent_chat_send_fun: fn target, text, opts ->
        send(test_pid, {:sent, target, text, Keyword.fetch!(opts, :message_id)})
        Agent.get_and_update(agent, fn [reply | rest] -> {reply, rest} end)
      end
    )
  end

  defp stub_status(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    EndpointStubs.put(agent_chat_delivery_status_fun: fn _id, _timeout -> Agent.get_and_update(agent, fn [r | rest] -> {r, if(rest == [], do: [r], else: rest)} end) end)
  end

  defp open do
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    id = hd(Enum.filter(data()["sections"]["now"], &(&1["agent"] != nil and &1["start"] != nil)))["id"]
    render_hook(view, "conversation-page", %{id: id})
    assert_reply(view, conversation)
    {view, id, conversation}
  end

  defp send_text(view, params) do
    render_hook(view, "send", params)
    assert_reply(view, reply)
    assert Payload.validate(reply) == :ok
    reply
  end

  test "the open conversation says the composer is ready for a unique running agent" do
    {_view, _id, conversation} = open()
    assert conversation["composer"] == "ready"
    assert Payload.validate(conversation) == :ok
  end

  test "voice availability is explicit for available, unavailable and read-only composers" do
    {view, _id, _conversation} = open()

    Application.put_env(:aiur, :voice_provider, ConfiguredVoice)
    render_hook(view, "voice-availability", %{})
    assert_reply(view, %{state: "available"})

    Application.put_env(:aiur, :voice_provider, UnconfiguredVoice)
    render_hook(view, "voice-availability", %{})

    assert_reply(view, %{
      state: "unconfigured",
      reason: "ElevenLabs speech-to-text is not configured. Dictation is unavailable; ask the Executor to run `aiur init` and add an ElevenLabs API key."
    })

    Application.put_env(:aiur, :voice_provider, AiurWeb.BuildLiveComposerMissingVoice)
    render_hook(view, "voice-availability", %{})
    assert_reply(view, %{state: "unconfigured", reason: "Voice input isn't installed in this Aiur. Typed messages work as usual."})

    EndpointStubs.put(dashboard_writable: false)
    render_hook(view, "voice-availability", %{})
    assert_reply(view, %{state: "read_only", reason: "Read-only dashboard — dictation is off."})
  end

  test "an accepted send reaches the delivery API with the open ticket's id and trimmed text" do
    stub_send([{:ok, 7}])
    stub_status([{:ok, :pending}])
    {view, id, _} = open()

    reply = send_text(view, %{"id" => id, "text" => "  continue  "})
    assert_received {:sent, ^id, "continue", "dashboard-" <> _}
    assert %{"ok" => true, "request_id" => 7, "text" => "continue", "id" => ^id} = reply
    assert reply["entry_id"] == OperatorSend.transcript_id(7)
  end

  test "empty and whitespace-only text is refused and never sent" do
    stub_send([])
    {view, id, _} = open()

    for text <- ["", "   ", "\n\t "] do
      assert %{"ok" => false, "reason" => "empty_message", "message" => "Message is empty."} = send_text(view, %{"id" => id, "text" => text})
    end

    refute_received {:sent, _, _, _}
  end

  test "a dashboard turned read-only after mount refuses the send" do
    stub_send([{:ok, 7}])
    {view, id, _} = open()
    EndpointStubs.put(dashboard_writable: false)

    assert send_text(view, %{"id" => id, "text" => "go"}) == %{"v" => 1, "kind" => "error", "reason" => "read_only"}
    refute_received {:sent, _, _, _}
  end

  # #2717 through the composer: same text after an unknown outcome reuses the id.
  test "an unknown outcome keeps the id for a retry and says so without claiming failure" do
    unknown = {:error, {:outcome_unknown, %{item_id: nil}}}
    stub_send([unknown, unknown, unknown])
    {view, id, _} = open()

    reply = send_text(view, %{"id" => id, "text" => "go"})
    assert %{"ok" => false, "reason" => "outcome_unknown", "unknown" => true} = reply
    assert reply["message"] == AgentLogModal.format_error({:outcome_unknown, nil})
    assert_received {:sent, _, "go", first}
    send_text(view, %{"id" => id, "text" => "go"})
    assert_received {:sent, _, "go", ^first}
    send_text(view, %{"id" => id, "text" => "go on"})
    assert_received {:sent, _, "go on", edited}
    refute edited == first
  end

  test "the client cannot name a target: bad ids, other tickets and ambiguous targets send nothing", %{control: control} do
    stub_send([{:ok, 7}])
    {view, id, _} = open()

    assert send_text(view, %{"id" => "abc", "text" => "go"})["reason"] == "invalid_params"
    assert send_text(view, %{})["reason"] == "invalid_params"
    assert %{"ok" => false, "reason" => "no_running_agent"} = send_text(view, %{"id" => "999999", "text" => "go"})

    Agent.update(control, &Map.put(&1, :running, [%{identifier: id}, %{identifier: id}]))
    render_hook(view, "conversation-page", %{id: id})
    assert_reply(view, %{"composer" => "ambiguous"})
    assert %{"ok" => false, "reason" => "ambiguous_identifier"} = send_text(view, %{"id" => id, "text" => "go"})
    refute_received {:sent, _, _, _}
  end

  test "no running agent leaves no composer and sends nothing", %{control: control} do
    stub_send([{:ok, 7}])
    Agent.update(control, &Map.put(&1, :running, []))
    {view, id, conversation} = open()
    assert conversation["composer"] == nil
    assert %{"ok" => false, "reason" => "no_running_agent", "message" => "Agent is no longer running."} = send_text(view, %{"id" => id, "text" => "go"})
    refute_received {:sent, _, _, _}
  end

  test "known errors get fixed tags and copy; unmapped terms never reach the browser" do
    stub_send([
      {:error, :max_concurrent_agents_reached},
      {:error, :message_too_long},
      {:error, {:not_queued, :timeout}},
      {:error, {:weird, "/tmp/x"}},
      {:error, {:message_id_conflict, 42}}
    ])

    {view, id, _} = open()

    cap = send_text(view, %{"id" => id, "text" => "a"})
    assert cap["reason"] == "max_concurrent_agents_reached"
    assert cap["message"] == "No free agent slot, so the agent stays paused. Try again when a slot frees."
    assert %{"reason" => "message_too_long", "message" => "Message is too long."} = send_text(view, %{"id" => id, "text" => "b"})
    assert %{"reason" => "not_queued", "unknown" => false} = send_text(view, %{"id" => id, "text" => "c"})

    for text <- ["d", "e"] do
      reply = send_text(view, %{"id" => id, "text" => text})
      assert %{"reason" => "error", "message" => "Send failed. Check the log before you send again."} = reply
      Aiur.TestSupport.refute_leak(reply, "/tmp/x")
      Aiur.TestSupport.refute_leak(reply, "message_id_conflict")
    end
  end

  test "delivery poll says queued once, then delivered only from a delivered read" do
    stub_send([{:ok, 7}])
    stub_status([{:ok, :pending}, {:ok, :pending}, {:ok, :delivered}])
    {view, id, _} = open()
    send_text(view, %{"id" => id, "text" => "go"})

    assert_push_event(view, "send-status", %{"status" => "queued", "request_id" => 7, "id" => ^id}, 1_000)
    assert_push_event(view, "send-status", %{"status" => "delivered", "request_id" => 7}, 1_000)
    refute_push_event(view, "send-status", %{"status" => "queued"}, 50)
  end

  test "a status that stays pending or unreadable ends unconfirmed, never delivered or failed" do
    for reply <- [{:ok, :pending}, {:error, :unknown_message}] do
      stub_send([{:ok, 7}])
      stub_status([reply])
      {view, id, _} = open()
      send_text(view, %{"id" => id, "text" => "go"})

      assert_push_event(view, "send-status", %{"status" => "unconfirmed"}, 1_000)
      refute_push_event(view, "send-status", %{"status" => "delivered"}, 50)
      refute_push_event(view, "send-status", %{"status" => "failed"}, 0)
    end
  end

  test "superseded and failed deliveries are reported as such" do
    for status <- [:superseded, :failed] do
      stub_send([{:ok, 7}])
      stub_status([{:ok, status}])
      {view, id, _} = open()
      send_text(view, %{"id" => id, "text" => "go"})
      expected = Atom.to_string(status)
      assert_push_event(view, "send-status", %{"status" => ^expected}, 1_000)
    end
  end

  # Polls are driven by hand here so the test does not depend on timer order.
  test "only the latest send on a ticket is polled" do
    stub_send([{:ok, 7}, {:ok, 8}])
    stub_status([{:ok, :delivered}])
    Application.put_env(:aiur, :build_send_status_delays_ms, [60_000])
    {view, id, _} = open()
    send_text(view, %{"id" => id, "text" => "one"})
    send_text(view, %{"id" => id, "text" => "two"})

    send(view.pid, {:send_status_poll, id, 7, 0})
    send(view.pid, {:send_status_poll, id, 8, 0})
    assert_push_event(view, "send-status", %{"status" => "delivered", "request_id" => 8}, 1_000)
    refute_push_event(view, "send-status", %{"request_id" => 7}, 100)
  end

  test "closing the conversation stops the poll" do
    stub_send([{:ok, 7}])
    stub_status([{:ok, :delivered}])
    Application.put_env(:aiur, :build_send_status_delays_ms, [60_000])
    {view, id, _} = open()
    send_text(view, %{"id" => id, "text" => "go"})
    render_hook(view, "conversation-close", %{id: id})

    send(view.pid, {:send_status_poll, id, 7, 0})
    refute_push_event(view, "send-status", %{}, 200)
  end

  # EC-13: each tab is its own user action, so two tabs never share an id.
  test "two tabs sending the same text produce two messages" do
    stub_send([{:ok, 7}, {:ok, 8}])
    {first, id, _} = open()
    {second, ^id, _} = open()
    send_text(first, %{"id" => id, "text" => "same"})
    send_text(second, %{"id" => id, "text" => "same"})
    assert_received {:sent, _, "same", a}
    assert_received {:sent, _, "same", b}
    refute a == b
  end
end
