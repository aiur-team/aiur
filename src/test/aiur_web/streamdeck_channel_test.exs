defmodule AiurWeb.StreamdeckChannelTest do
  alias Aiur.TestSupport.BuildHome.UsageInputs
  use AiurWeb.StreamdeckChannelCase

  setup do
    inputs = UsageInputs.inputs(%{meters: %{codex: UsageInputs.snapshot(:codex, %{"primary" => UsageInputs.window(42)})}})
    put_endpoint_config(streamdeck_usage_load_fun: fn _, _ -> inputs end)
    :ok
  end

  test "only a socket authenticated by dashboard credentials can join" do
    assert :error = StreamdeckSocket.connect(%{}, socket(StreamdeckSocket, "untrusted", %{}), %{})
    assert :error = StreamdeckSocket.connect(%{"token" => "not-a-token"}, socket(StreamdeckSocket, "untrusted", %{}), %{})

    assert {:error, %{reason: "unauthorized"}} =
             join(socket(StreamdeckSocket, "untrusted", %{}), "streamdeck:fleet")

    assert {:ok, token} = StreamdeckAuth.issue_token()
    assert {:ok, authenticated} = StreamdeckSocket.connect(%{"token" => token}, socket(StreamdeckSocket, "trusted", %{}), %{})
    assert {:ok, _reply, _socket} = subscribe_and_join(authenticated, "streamdeck:fleet")
  end

  # The join guard is the defence-in-depth boundary on a channel that writes
  # decisions, so it must reject an explicitly-false authentication assign —
  # not only the absent-assign socket the connect flow normally produces. The
  # first `join/3` clause pattern-matches `streamdeck_authenticated: true`; a
  # false assign falls through to the unauthorized clause.
  test "a socket with an explicitly false authentication assign cannot join" do
    false_assign =
      %{socket(StreamdeckSocket, "untrusted", %{}) | assigns: %{streamdeck_authenticated: false}}

    assert {:error, %{reason: "unauthorized"}} = join(false_assign, "streamdeck:fleet")

    forged_assign = %{
      socket(StreamdeckSocket, "untrusted", %{})
      | assigns: %{streamdeck_authenticated: false, streamdeck_expires_at_ms: 0, streamdeck_generation: 1}
    }

    assert {:error, %{reason: "unauthorized"}} = join(forged_assign, "streamdeck:fleet")
  end

  test "socket tokens are invalidated when dashboard credentials change" do
    assert {:ok, token} = StreamdeckAuth.issue_token()

    System.put_env("AIUR_DASHBOARD_PASSWORD", "rotated-secret")

    assert :error = StreamdeckAuth.verify_token(token)
  end

  test "socket tokens survive a financial-data read of the configuration generation" do
    assert {:ok, token} = StreamdeckAuth.issue_token()

    # Dashboard reads inherit `dashboard_auth_required` while token issuance
    # always demands `required?: true`. Only credentials may rotate the shared
    # configuration generation — a differing policy flag must not.
    assert {:ok, _generation} = FinancialDataAccess.current_configuration_generation()

    assert {:ok, _generation, _expires_at_ms} = StreamdeckAuth.verify_token(token)
  end

  test "a joined channel survives a financial-data read while focused" do
    socket = joined_socket()
    focus = push(socket, "focus", %{"identifier" => "AIUR-1"})
    assert_reply(focus, :ok, %{"focused" => "AIUR-1"}, 1_000)
    channel_barrier(socket)

    assert {:ok, _generation} = FinancialDataAccess.current_configuration_generation()

    AgentPubSub.broadcast_alert("AIUR-1", AgentEvents.alert_event("test", "still connected"))
    assert_push("alert", %{"identifier" => "AIUR-1", "message" => "still connected"})
  end

  test "a joined channel closes when dashboard credentials change" do
    assert {:ok, token} = StreamdeckAuth.issue_token()
    assert {:ok, socket} = StreamdeckSocket.connect(%{"token" => token}, socket(StreamdeckSocket, "authenticated", %{}), %{})
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "streamdeck:fleet")
    monitor = Process.monitor(socket.channel_pid)

    focus = push(socket, "focus", %{"identifier" => "AIUR-1"})
    assert_reply(focus, :ok, %{"focused" => "AIUR-1"}, 1_000)
    timer = :sys.get_state(socket.channel_pid).assigns.deck_chat.timer

    System.put_env("AIUR_DASHBOARD_PASSWORD", "rotated-secret")
    assert :error = StreamdeckAuth.verify_token(token)

    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 200
    assert Process.read_timer(timer) == false
  end

  test "the token endpoint fails closed when dashboard credentials are absent" do
    System.delete_env("AIUR_DASHBOARD_USERNAME")
    System.delete_env("AIUR_DASHBOARD_PASSWORD")

    response = Endpoint.call(conn(:post, "/api/v1/streamdeck/token"), Endpoint.init([]))

    assert response.status == 401
    assert response.resp_body == "Unauthorized"
    assert {:error, :authentication_required} = StreamdeckAuth.issue_token()
  end

  test "the short-lived socket token is issued only after dashboard Basic authentication" do
    missing = Endpoint.call(conn(:post, "/api/v1/streamdeck/token"), Endpoint.init([]))
    assert missing.status == 401

    authorized =
      :post
      |> conn("/api/v1/streamdeck/token")
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
      |> Endpoint.call(Endpoint.init([]))

    assert authorized.status == 200
    assert %{"token" => token, "expires_in_seconds" => 300} = Jason.decode!(authorized.resp_body)
    assert {:ok, _generation, _expires_at_ms} = StreamdeckAuth.verify_token(token)
  end

  test "a client bearer token can request and revoke Stream Deck socket credentials" do
    path = Path.join(System.tmp_dir!(), "aiur-streamdeck-client-token-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:aiur, :client_tokens_path)
    Application.put_env(:aiur, :client_tokens_path, path)
    assert {:ok, client_token} = Aiur.ClientTokens.create("stream-deck", "write")

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :client_tokens_path, previous), else: Application.delete_env(:aiur, :client_tokens_path)
      Aiur.TestCleanup.rm_rf!(path)
    end)

    authorized =
      :post
      |> conn("/api/v1/streamdeck/token")
      |> put_req_header("authorization", "Bearer #{client_token}")
      |> Endpoint.call(Endpoint.init([]))

    assert authorized.status == 200
    assert %{"token" => socket_token, "expires_in_seconds" => 300} = Jason.decode!(authorized.resp_body)
    assert {:ok, _generation, _expires_at_ms} = StreamdeckAuth.verify_token(socket_token)

    assert :ok = Aiur.ClientTokens.revoke("stream-deck")

    revoked =
      :post
      |> conn("/api/v1/streamdeck/token")
      |> put_req_header("authorization", "Bearer #{client_token}")
      |> Endpoint.call(Endpoint.init([]))

    assert revoked.status == 401
  end

  test "expired socket tokens are rejected even when their signature is valid" do
    assert {:ok, token} = StreamdeckAuth.issue_token()
    assert {:ok, generation, _expires_at_ms} = StreamdeckAuth.verify_token(token)

    expired_token =
      Phoenix.Token.sign(Endpoint, "streamdeck-v1", %{
        generation: generation,
        expires_at_ms: System.system_time(:millisecond) - 1
      })

    assert :error = StreamdeckAuth.verify_token(expired_token)
  end

  test "a joined channel closes when its socket token expires" do
    socket =
      authenticated_socket()
      # Joining performs several subscriptions and a snapshot before returning
      # the test socket. Keep enough time for that setup to finish under a
      # loaded test suite, then verify the channel closes on expiry.
      |> Phoenix.Socket.assign(:streamdeck_expires_at_ms, System.system_time(:millisecond) + 1_000)

    assert {:ok, _reply, socket} = subscribe_and_join(socket, "streamdeck:fleet")
    monitor = Process.monitor(socket.channel_pid)

    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 1_500
  end

  test "join pushes a complete external snapshot" do
    socket = authenticated_socket()
    assert {:ok, _reply, _socket} = subscribe_and_join(socket, "streamdeck:fleet")

    assert_push("snapshot", %{
      "version" => 1,
      "fleet" => %{"agents" => [%{"identifier" => "AIUR-1", "title" => "Channel tests"}]},
      "usage" => %{"codex" => %{"state" => "observed"}},
      "decisions" => %{"count" => 2}
    })
  end

  test "a fleet PubSub broadcast reaches the joined socket as a fleet event" do
    joined_socket()
    summary = AgentEvents.agent_summary("AIUR-2", :running, 1, %{title: "Pushed"})
    put_endpoint_config(streamdeck_snapshot_fun: fn -> %{agents: [summary]} end)
    StreamdeckFleetFixture.broadcast_running_change([summary])

    assert_receive %Message{
                     topic: "streamdeck:fleet",
                     event: "fleet",
                     payload: %{"agents" => [%{"identifier" => "AIUR-2", "status" => "running", "title" => "Pushed"}]} = payload
                   },
                   500

    refute Map.has_key?(payload, :agents)
  end

  test "agent-list status details trigger a fresh fleet projection instead of leaking pane internals" do
    joined_socket()
    StreamdeckFleetFixture.broadcast_status_change("AIUR-1", :pane_opened)

    receive_barrier(%Message{event: "fleet", payload: %{"agents" => [%{"identifier" => "AIUR-1", "title" => "Channel tests"}]}})
  end

  test "focus subscribes only to the focused agent and drops the prior subscription" do
    socket = joined_socket()
    first_focus = push(socket, "focus", %{"identifier" => "AIUR-1"})
    assert_reply(first_focus, :ok, %{"focused" => "AIUR-1"}, 1_000)
    receive_barrier(%Message{event: "chat"})

    AgentPubSub.broadcast_alert("AIUR-1", AgentEvents.alert_event("test", "first"))
    assert_push("alert", %{"identifier" => "AIUR-1", "message" => "first"})

    second_focus = push(socket, "focus", %{"identifier" => "AIUR-2"})
    assert_reply(second_focus, :ok, %{"focused" => "AIUR-2"}, 1_000)
    channel_barrier(socket)
    receive_barrier(%Message{event: "chat"})

    AgentPubSub.broadcast_alert("AIUR-1", AgentEvents.alert_event("test", "ignored"))
    channel_barrier(socket)
    refute_received %Message{event: "alert"}

    AgentPubSub.broadcast_alert("AIUR-2", AgentEvents.alert_event("test", "second"))
    assert_push("alert", %{"identifier" => "AIUR-2", "message" => "second"})
  end

  test "focus validates identifiers and unfocus stops the focused subscription" do
    socket = joined_socket()

    invalid = push(socket, "focus", %{"identifier" => ""})
    assert_reply(invalid, :error, %{reason: "invalid_identifier"}, 1_000)

    initial_unfocus = push(socket, "unfocus", %{})
    receive_barrier(%Phoenix.Socket.Reply{ref: ^initial_unfocus, status: :ok, payload: %{"focused" => nil}})

    focus = push(socket, "focus", %{"identifier" => "AIUR-1"})
    receive_barrier(%Phoenix.Socket.Reply{ref: ^focus, status: :ok, payload: %{"focused" => "AIUR-1"}})

    unfocus = push(socket, "unfocus", %{})
    receive_barrier(%Phoenix.Socket.Reply{ref: ^unfocus, status: :ok, payload: %{"focused" => nil}})

    AgentPubSub.broadcast_alert("AIUR-1", AgentEvents.alert_event("test", "ignored"))
    channel_barrier(socket)
    refute_received %Message{event: "alert"}
  end

  test "unfocus invalidates focus work that is already queued" do
    socket = joined_socket()
    pid = socket.channel_pid
    :sys.suspend(pid)

    focus = push(socket, "focus", %{"identifier" => "AIUR-1"})
    unfocus = push(socket, "unfocus", %{})

    :sys.resume(pid)

    assert_reply(focus, :ok, %{"focused" => "AIUR-1"}, 5_000)
    assert_reply(unfocus, :ok, %{"focused" => nil}, 5_000)

    %{assigns: assigns} = :sys.get_state(pid)
    assert assigns.focused_agent == nil
    assert assigns.focus_token == nil
    assert assigns.deck_chat == nil
  end

  test "focused alerts and control updates are projected without exposing the internal topic" do
    socket = joined_socket()
    focus = push(socket, "focus", %{"identifier" => "AIUR-1"})
    assert_reply(focus, :ok, %{"focused" => "AIUR-1"}, 1_000)
    receive_barrier(%Message{event: "chat"})

    AgentPubSub.broadcast_alert("AIUR-1", AgentEvents.alert_event("deploy", "Needs attention", severity: "warning"))

    assert_push("alert", %{
      "identifier" => "AIUR-1",
      "name" => "deploy",
      "message" => "Needs attention",
      "severity" => "warning",
      "needs_attention" => false
    })

    AgentPubSub.broadcast_control_lifecycle("AIUR-1", %{
      action: :pause,
      status: :paused,
      request_id: "internal-request",
      issue_id: 123,
      requester: "operator",
      reason: "operator"
    })

    assert_push("control", %{
      "identifier" => "AIUR-1",
      "state" => %{"action" => "pause", "status" => "paused"}
    })
  end

  test "a tagged event from the old focus cannot be relabeled after refocusing" do
    socket = joined_socket()
    first_focus = push(socket, "focus", %{"identifier" => "AIUR-1"})
    assert_reply(first_focus, :ok, %{"focused" => "AIUR-1"}, 1_000)

    second_focus = push(socket, "focus", %{"identifier" => "AIUR-2"})
    assert_reply(second_focus, :ok, %{"focused" => "AIUR-2"}, 1_000)

    send(socket.channel_pid, {:streamdeck_alert, "AIUR-1", AgentEvents.alert_event("stale", "stale")})
    channel_barrier(socket)
    refute_received %Message{event: "alert"}
  end

  test "a deferred stale refocus cannot replace the active chat timer" do
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"}, 1_000)
    receive_barrier(%Message{event: "chat"})
    %{assigns: %{deck_chat: chat, focus_token: focus_token}} = :sys.get_state(socket.channel_pid)
    send(socket.channel_pid, {:streamdeck_focus_changed, "AIUR-1", make_ref(), socket})
    %{assigns: %{deck_chat: current_chat, focus_token: current_token}} = :sys.get_state(socket.channel_pid)
    assert current_chat.timer == chat.timer
    assert current_token == focus_token
    assert is_integer(Process.read_timer(chat.timer))
  end

  test "legacy transcript events no longer push transcript frames" do
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"}, 1_000)
    receive_barrier(%Message{event: "chat"})
    AgentPubSub.broadcast_transcript("AIUR-1", AgentEvents.transcript_event(:assistant, "legacy"))
    channel_barrier(socket)
    refute_received %Message{event: "transcript"}
  end

  test "provider changes coalesce and reload Build usage instead of using event payloads" do
    socket = joined_socket()
    parent = self()

    inputs =
      UsageInputs.inputs(%{meters: %{codex: UsageInputs.snapshot(:codex, %{"primary" => UsageInputs.window(88)})}})

    put_endpoint_config(
      streamdeck_usage_load_fun: fn _, _ ->
        send(parent, :usage_loaded)
        inputs
      end
    )

    event = ProviderMeterSnapshot.empty(:codex, :app_server, "streamdeck-test-generation")
    ProviderMeterEvents.broadcast(event)
    ProviderMeterEvents.broadcast(event)
    receive_barrier(%Message{event: "usage", payload: %{"codex" => %{"windows" => %{"session" => %{"remaining_percent" => 12, "used_percent" => 88}}}}})
    :sys.get_state(socket.channel_pid)
    assert_received :usage_loaded
    refute_received :usage_loaded
    refute_received %Message{event: "usage"}
  end

  test "decision changes reach the joined socket through the decision summary" do
    socket = joined_socket()
    send(socket.channel_pid, {:decision_changed, "dec-1", 2})

    assert_push("decisions", %{"count" => 2})

    send(socket.channel_pid, :decision_metrics_changed)
    assert_push("decisions", %{"count" => 2})
  end

  # Focus acknowledges before its queued focus-change handler projects the logs
  # frame. Reading the channel state synchronously waits for that prior message
  # to finish without adding another timed wire reply to the test mailbox.
  defp channel_barrier(socket), do: :sys.get_state(socket.channel_pid)
end
