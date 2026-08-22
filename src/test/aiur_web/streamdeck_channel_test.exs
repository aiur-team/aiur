defmodule AiurWeb.StreamdeckChannelTest do
  use ExUnit.Case, async: false

  setup {AiurWeb.DashboardCredentialSupport, :isolate}
  import Phoenix.ChannelTest

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  alias Aiur.{AgentEvents, IssueLog}
  alias Aiur.AgentPubSub
  alias Aiur.ProviderMeters.Events, as: ProviderMeterEvents
  alias Aiur.ProviderMeterSnapshot
  alias AiurWeb.{Endpoint, FinancialDataAccess, StreamdeckAuth, StreamdeckChannel, StreamdeckProjection, StreamdeckSocket}
  alias Phoenix.Socket.Message
  alias Phoenix.Socket.V2.JSONSerializer

  @endpoint Endpoint

  setup do
    original_config = Application.get_env(:aiur, Endpoint, [])
    original_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    original_password = System.get_env("AIUR_DASHBOARD_PASSWORD")

    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")

    # The voice session fake runs inside the channel, not the test process, so
    # it reaches this test through a registered name rather than a closure.
    Process.register(self(), :streamdeck_channel_test_observer)

    config =
      original_config
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_auth_required: false,
        streamdeck_snapshot_fun: fn -> snapshot() end,
        streamdeck_provider_meters_fun: fn -> %{codex: %{state: :observed}, claude: %{state: :unknown}} end,
        streamdeck_decisions_fun: fn -> %{count: 2} end,
        streamdeck_transcript_flush_ms: 20
      )

    Application.put_env(:aiur, Endpoint, config)

    configure_endpoint(config)

    on_exit(fn ->
      Application.put_env(:aiur, Endpoint, original_config)
      restore_env("AIUR_DASHBOARD_USERNAME", original_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", original_password)
    end)

    :ok
  end

  defp configure_endpoint(config) do
    case Process.whereis(Endpoint) do
      nil ->
        start_supervised!({Endpoint, []})

      _pid ->
        Endpoint.config_change(config, [])
        Process.sleep(20)

        if is_nil(Process.whereis(Endpoint)) do
          start_supervised!({Endpoint, []})
        else
          Endpoint.config_change(config, [])
        end
    end
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
    assert_reply(focus, :ok, %{"focused" => "AIUR-1"})

    assert {:ok, _generation} = FinancialDataAccess.current_configuration_generation()

    AgentPubSub.broadcast_transcript("AIUR-1", AgentEvents.transcript_event(:assistant, "still connected"))
    assert_push("transcript", %{"identifier" => "AIUR-1", "body" => "still connected"})
  end

  test "a joined channel closes when dashboard credentials change" do
    assert {:ok, token} = StreamdeckAuth.issue_token()
    assert {:ok, socket} = StreamdeckSocket.connect(%{"token" => token}, socket(StreamdeckSocket, "authenticated", %{}), %{})
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "streamdeck:fleet")
    monitor = Process.monitor(socket.channel_pid)

    focus = push(socket, "focus", %{"identifier" => "AIUR-1"})
    assert_reply(focus, :ok, %{"focused" => "AIUR-1"})
    relay = :sys.get_state(socket.channel_pid).assigns.transcript_relay
    relay_monitor = Process.monitor(relay)

    System.put_env("AIUR_DASHBOARD_PASSWORD", "rotated-secret")
    assert :error = StreamdeckAuth.verify_token(token)

    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 200
    assert_receive {:DOWN, ^relay_monitor, :process, ^relay, :normal}, 200
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
      |> Phoenix.Socket.assign(:streamdeck_expires_at_ms, System.system_time(:millisecond) + 20)

    assert {:ok, _reply, socket} = subscribe_and_join(socket, "streamdeck:fleet")
    monitor = Process.monitor(socket.channel_pid)

    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 200
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
    socket = joined_socket()
    AgentPubSub.broadcast_running_change([AgentEvents.agent_summary("AIUR-2", :running, 1, %{title: "Pushed"})])

    assert_receive %Message{
                     topic: "streamdeck:fleet",
                     event: "fleet",
                     payload: %{"agents" => [%{"identifier" => "AIUR-2", "status" => "running", "title" => "Pushed"}]} = payload
                   },
                   500

    refute Map.has_key?(payload, :agents)
    refute Map.has_key?(payload, :grid)
    assert socket.assigns.streamdeck_authenticated
  end

  test "agent-list status details trigger a fresh fleet projection instead of leaking pane internals" do
    joined_socket()
    AgentPubSub.broadcast_status_change("AIUR-1", :pane_opened)

    assert_push("fleet", %{"agents" => [%{"identifier" => "AIUR-1", "title" => "Channel tests"}]})
  end

  test "focus subscribes only to the focused agent and drops the prior subscription" do
    socket = joined_socket()
    first_focus = push(socket, "focus", %{"identifier" => "AIUR-1"})
    assert_reply(first_focus, :ok, %{"focused" => "AIUR-1"})

    AgentPubSub.broadcast_transcript("AIUR-1", AgentEvents.transcript_event(:assistant, "first"))
    assert_push("transcript", %{"identifier" => "AIUR-1", "body" => "first"})

    second_focus = push(socket, "focus", %{"identifier" => "AIUR-2"})
    assert_reply(second_focus, :ok, %{"focused" => "AIUR-2"})

    AgentPubSub.broadcast_transcript("AIUR-1", AgentEvents.transcript_event(:assistant, "ignored"))
    refute_push("transcript", _payload, 50)

    AgentPubSub.broadcast_transcript("AIUR-2", AgentEvents.transcript_event(:assistant, "second"))
    assert_push("transcript", %{"identifier" => "AIUR-2", "body" => "second"})
  end

  test "pushes a nonempty JSON-safe logs frame through the Phoenix channel" do
    identifier = "streamdeck-wire-#{System.unique_integer([:positive])}"
    path = IssueLog.transcript_path(identifier)
    File.mkdir_p!(Path.dirname(path))

    on_exit(fn -> File.rm(path) end)

    File.write!(
      path,
      Jason.encode!(%{
        "role" => "assistant",
        "body" => "serialized transcript",
        "timestamp" => "2026-07-30T00:00:00Z",
        "msg_id" => "message-1",
        "sequence" => 1,
        "turn_id" => "turn-1",
        "payload" => nil
      }) <> "\n"
    )

    write_event_log(identifier, [
      event_line(7, "emit", "ticket.401.pr.merged", "PR #1904 merged", "2026-07-30T00:05:00Z")
    ])

    socket = joined_socket()
    focus = push(socket, "focus", %{"identifier" => identifier})
    assert_reply(focus, :ok, %{"focused" => ^identifier})

    # `assert_push/2` receives the decoded Phoenix socket payload, proving the
    # nonempty DTO crossed the channel serializer rather than only Jason.encode/1
    # on the projection helper.
    assert_push("logs", payload)

    # One key per shared-event-bus row, anchored by the synthesised origin at
    # index 0 and closed by LIVE at the end. A transcript turn is a detail row
    # underneath an event now, so no key is keyed by `turn:<id>` any more.
    assert Enum.map(payload["event_keys"], & &1["id"]) == ["origin", "bus:emit:7", "live"]
    assert Enum.map(payload["event_keys"], & &1["kind"]) == ["event", "event", "live"]
    refute Enum.any?(payload["event_keys"], &String.starts_with?(&1["id"], "turn:"))

    # Each key carries the offset of its own header, which is what a press jumps
    # to; LIVE's is the newest row rather than a header of its own.
    assert payload["event_starts"] == %{"0" => 0, "1" => 2}
    assert payload["event_keys"] |> List.last() |> Map.get("start") == length(payload["transcript"]) - 1
    assert Enum.any?(payload["transcript"], &(&1["body"] == "serialized transcript"))

    assert {:socket_push, :text, frame} =
             JSONSerializer.encode!(%Message{
               topic: "streamdeck:fleet",
               event: "logs",
               payload: payload,
               ref: nil,
               join_ref: "1"
             })

    assert ["1", nil, "streamdeck:fleet", "logs", ^payload] =
             frame |> IO.iodata_to_binary() |> Jason.decode!()
  end

  # The transcript on the logs surface is what the event keys jump into, so it
  # has to follow focus. Only the `transcript` frame was covered before, which
  # would still pass if the logs frame kept projecting the first agent's feed.
  test "the logs frame re-scopes to the newly focused agent" do
    first = write_transcript("streamdeck-focus-a", "first agent body", "turn-a")
    second = write_transcript("streamdeck-focus-b", "second agent body", "turn-b")
    write_event_log(first, [event_line(11, "emit", "ticket.401.pr.opened", "first agent event", "2026-07-30T00:00:00Z")])
    write_event_log(second, [event_line(22, "emit", "ticket.402.pr.merged", "second agent event", "2026-07-30T00:00:00Z")])

    socket = joined_socket()

    assert_reply(push(socket, "focus", %{"identifier" => first}), :ok, %{"focused" => ^first})
    assert_push("logs", first_payload)
    assert Enum.any?(first_payload["transcript"], &(&1["body"] == "first agent body"))

    assert_reply(push(socket, "focus", %{"identifier" => second}), :ok, %{"focused" => ^second})
    assert_push("logs", second_payload)
    assert Enum.any?(second_payload["transcript"], &(&1["body"] == "second agent body"))
    refute Enum.any?(second_payload["transcript"], &(&1["body"] == "first agent body"))

    # The headers are what the device derives its jump targets from, so a
    # transcript that carried only message rows would still fail the operator.
    assert Enum.any?(second_payload["transcript"], &(&1["kind"] == "event_header"))

    # Event keys are per-ticket bus rows, so the previous agent's key has to be
    # gone from the frame rather than merely outnumbered by the new agent's.
    assert Enum.any?(second_payload["event_keys"], &(&1["id"] == "bus:emit:22"))
    refute Enum.any?(second_payload["event_keys"], &(&1["id"] == "bus:emit:11"))
  end

  test "focus validates identifiers and unfocus stops the focused subscription" do
    socket = joined_socket()

    invalid = push(socket, "focus", %{"identifier" => ""})
    assert_reply(invalid, :error, %{reason: "invalid_identifier"})

    initial_unfocus = push(socket, "unfocus", %{})
    assert_reply(initial_unfocus, :ok, %{"focused" => nil})

    focus = push(socket, "focus", %{"identifier" => "AIUR-1"})
    assert_reply(focus, :ok, %{"focused" => "AIUR-1"})

    unfocus = push(socket, "unfocus", %{})
    assert_reply(unfocus, :ok, %{"focused" => nil})

    AgentPubSub.broadcast_transcript("AIUR-1", AgentEvents.transcript_event(:assistant, "ignored"))
    refute_push("transcript", _payload, 50)
  end

  test "focused alerts and control updates are projected without exposing the internal topic" do
    socket = joined_socket()
    focus = push(socket, "focus", %{"identifier" => "AIUR-1"})
    assert_reply(focus, :ok, %{"focused" => "AIUR-1"})

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
    assert_reply(first_focus, :ok, %{"focused" => "AIUR-1"})

    second_focus = push(socket, "focus", %{"identifier" => "AIUR-2"})
    assert_reply(second_focus, :ok, %{"focused" => "AIUR-2"})

    send(socket.channel_pid, {:streamdeck_transcript, "AIUR-1", AgentEvents.transcript_event(:assistant, "stale")})
    refute_push("transcript", _payload, 50)
  end

  test "a transcript burst is coalesced to one latest event" do
    socket = joined_socket()
    focus = push(socket, "focus", %{"identifier" => "AIUR-1"})
    assert_reply(focus, :ok, %{"focused" => "AIUR-1"})

    for number <- 1..25 do
      AgentPubSub.broadcast_transcript("AIUR-1", AgentEvents.transcript_event(:assistant, "line #{number}"))
    end

    assert_push("transcript", %{"body" => "line 25"})
    refute_push("transcript", _payload, 50)
  end

  test "provider changes reach the joined socket through the redacted usage projection" do
    joined_socket()

    snapshot = %{
      ProviderMeterSnapshot.empty(:codex, :app_server, "streamdeck-test-generation")
      | observed_at: ~U[2026-07-30 12:00:00Z],
        auth_mode: :subscription,
        freshness: :fresh,
        plan: %{tier: "updated"}
    }

    ProviderMeterEvents.broadcast(snapshot)

    assert_push("usage", %{
      "claude" => %{"state" => "unknown"},
      "codex" => %{
        "state" => "observed",
        "provider" => "codex",
        "auth_mode" => "subscription",
        "freshness" => "stale",
        "observed_at" => "2026-07-30T12:00:00Z",
        "plan" => %{"tier" => "updated"}
      }
    })
  end

  test "unobserved provider events retain the current usage projection" do
    joined_socket()
    ProviderMeterEvents.broadcast(ProviderMeterSnapshot.empty(:codex, :app_server, "streamdeck-test-generation"))

    assert_push("usage", %{"claude" => %{"state" => "unknown"}, "codex" => %{"state" => "observed"}})
  end

  test "older provider events retain the newer usage projection" do
    newer_observed_at = ~U[2026-07-30 12:01:00Z]

    older_snapshot = %{
      ProviderMeterSnapshot.empty(:codex, :app_server, "streamdeck-test-generation")
      | observed_at: ~U[2026-07-30 12:00:00Z],
        plan: %{tier: "older"}
    }

    assert %{"codex" => %{"state" => "observed", "observed_at" => "2026-07-30T12:01:00Z"}} =
             StreamdeckProjection.merge_provider_meter(
               %{"codex" => %{"state" => "observed", "observed_at" => DateTime.to_iso8601(newer_observed_at)}, "claude" => %{"state" => "unknown"}},
               older_snapshot
             )
  end

  test "decision changes reach the joined socket through the decision summary" do
    socket = joined_socket()
    send(socket.channel_pid, {:decision_changed, "dec-1", 2})

    assert_push("decisions", %{"count" => 2})

    send(socket.channel_pid, :decision_metrics_changed)
    assert_push("decisions", %{"count" => 2})
  end

  test "external projections convert source values to JSON-safe payloads" do
    timestamp = ~U[2026-07-30 12:00:00Z]

    assert %{
             "identifier" => "AIUR-3",
             "status" => "paused",
             "alert_count" => 3,
             "tracker_paused" => true,
             "backend" => "codex"
           } =
             StreamdeckProjection.agent(%{
               "identifier" => "AIUR-3",
               "status" => :paused,
               "alert_count" => 3,
               "tracker_paused" => true,
               "backend" => :codex
             })

    assert %{"identifier" => "AIUR-3", "role" => "assistant", "timestamp" => "2026-07-30T12:00:00Z"} =
             StreamdeckProjection.transcript("AIUR-3", %{role: :assistant, timestamp: timestamp})
  end

  test "a failed control action reports the same bare reason wording as say" do
    socket = joined_socket()
    control = push(socket, "control", %{"identifier" => "AIUR-1", "action" => "pause"})

    # One wire convention: an atom reason from the AgentChat facade reaches the
    # device as the bare word, never inspect-quoted (`":no_running_agent"`).
    # Which atom comes back depends on orchestrator state, so pin the wording,
    # not the value.
    assert_reply(control, :error, %{reason: reason})
    assert reason =~ ~r/^[a-z_]+$/
  end

  describe "say (voice input)" do
    test "delivers the spoken message through the AgentChat seam and replies with the request id" do
      test_pid = self()
      put_endpoint_config(agent_chat_send_fun: fn identifier, text -> send(test_pid, {:sent, identifier, text}) && {:ok, 42} end)

      socket = joined_socket()
      say = push(socket, "say", %{"identifier" => "AIUR-1", "text" => "  ship the fix  "})

      assert_reply(say, :ok, %{"request_id" => 42})
      # Trimmed, and delivered through the one existing chat path.
      assert_received {:sent, "AIUR-1", "ship the fix"}
    end

    test "surfaces a delivery error as a reason string" do
      put_endpoint_config(agent_chat_send_fun: fn _identifier, _text -> {:error, :no_agent} end)

      socket = joined_socket()
      say = push(socket, "say", %{"identifier" => "AIUR-1", "text" => "hello"})

      assert_reply(say, :error, %{reason: "no_agent"})
    end

    test "rejects a message that trims to empty without calling delivery" do
      test_pid = self()
      put_endpoint_config(agent_chat_send_fun: fn identifier, text -> send(test_pid, {:sent, identifier, text}) && {:ok, 1} end)

      socket = joined_socket()
      say = push(socket, "say", %{"identifier" => "AIUR-1", "text" => "   \n\t "})

      assert_reply(say, :error, %{reason: "empty_message"})
      refute_received {:sent, _identifier, _text}
    end

    test "rejects a message over the operator-message ceiling without calling delivery" do
      test_pid = self()
      put_endpoint_config(agent_chat_send_fun: fn identifier, text -> send(test_pid, {:sent, identifier, text}) && {:ok, 1} end)

      socket = joined_socket()
      say = push(socket, "say", %{"identifier" => "AIUR-1", "text" => String.duplicate("a", 8_001)})

      assert_reply(say, :error, %{reason: "message_too_long"})
      refute_received {:sent, _identifier, _text}

      at_ceiling = push(socket, "say", %{"identifier" => "AIUR-1", "text" => String.duplicate("a", 8_000)})
      assert_reply(at_ceiling, :ok, %{"request_id" => 1})
    end

    test "rejects malformed payloads" do
      socket = joined_socket()

      for payload <- [%{"identifier" => "AIUR-1"}, %{"text" => "hello"}, %{"identifier" => "AIUR-1", "text" => 7}, %{"identifier" => "", "text" => "hello"}] do
        reply = push(socket, "say", payload)
        assert_reply(reply, :error, %{reason: "invalid_message"})
      end
    end

    test "rejects an unauthenticated socket" do
      unauthenticated = %Phoenix.Socket{assigns: %{streamdeck_authenticated: false}}

      assert {:reply, {:error, %{reason: "unauthorized"}}, ^unauthenticated} =
               StreamdeckChannel.handle_in("say", %{"identifier" => "AIUR-1", "text" => "hello"}, unauthenticated)
    end
  end

  describe "voice input" do
    test "voice_start mints an opaque session and voice_audio relays the base64 frame verbatim" do
      put_endpoint_config(streamdeck_voice_session: __MODULE__.FakeVoiceSession)

      socket = joined_socket()
      start = push(socket, "voice_start", %{})
      assert_reply(start, :ok, %{"session" => session})

      # Opaque and server-minted: nothing the device sent decides it.
      assert is_binary(session) and byte_size(session) >= 12

      assert_receive {:voice_session_started, pid}

      push(socket, "voice_audio", %{"session" => session, "audio" => "Zm9vYmFy"})
      # Relayed exactly, because the provider's own frame wants this string.
      assert_receive {:voice_push, ^pid, "Zm9vYmFy"}

      stop = push(socket, "voice_stop", %{"session" => session})
      assert_reply(stop, :ok, %{})
      # Stop commits the utterance rather than killing it; the commit flush is
      # what settles the tail of what was just said.
      assert_receive {:voice_commit, ^pid}
    end

    test "no configured API key is reported as unconfigured rather than as a failure" do
      put_endpoint_config(streamdeck_voice_session: __MODULE__.UnconfiguredVoiceSession)

      socket = joined_socket()
      start = push(socket, "voice_start", %{})

      assert_reply(start, :error, %{"reason" => "unconfigured"})
    end

    test "rejects an unauthenticated socket" do
      unauthenticated = %Phoenix.Socket{assigns: %{streamdeck_authenticated: false}}

      assert {:reply, {:error, %{"reason" => "unauthorized"}}, ^unauthenticated} =
               StreamdeckChannel.handle_in("voice_start", %{}, unauthenticated)
    end

    test "a stale, unknown or oversized frame never reaches the provider" do
      put_endpoint_config(streamdeck_voice_session: __MODULE__.FakeVoiceSession)

      socket = joined_socket()
      assert_reply(push(socket, "voice_start", %{}), :ok, %{"session" => session})
      assert_receive {:voice_session_started, pid}

      for payload <- [
            %{"session" => "not-the-live-session", "audio" => "AAAA"},
            %{"session" => session},
            %{"session" => session, "audio" => 7},
            # A 100 ms frame is 4,272 base64 characters; this is far past any
            # ceiling a real capture could reach.
            %{"session" => session, "audio" => String.duplicate("A", 65_537)}
          ] do
        push(socket, "voice_audio", payload)
      end

      refute_receive {:voice_push, ^pid, _audio}, 50

      # A stop for a session that is not live is acknowledged and does nothing.
      assert_reply(push(socket, "voice_stop", %{"session" => "not-the-live-session"}), :ok, %{})
      refute_receive {:voice_commit, ^pid}, 50

      # And the channel is still alive and still serving the live session.
      push(socket, "voice_audio", %{"session" => session, "audio" => "AAAA"})
      assert_receive {:voice_push, ^pid, "AAAA"}
    end

    test "transcripts, errors and closure reach the device tagged with their session" do
      put_endpoint_config(streamdeck_voice_session: __MODULE__.FakeVoiceSession)

      socket = joined_socket()
      assert_reply(push(socket, "voice_start", %{}), :ok, %{"session" => session})
      assert_receive {:voice_session_started, pid}

      send(socket.channel_pid, {:elevenlabs_transcript, :partial, "ship the"})
      assert_push("voice", %{"session" => ^session, "kind" => "partial", "text" => "ship the"})

      send(socket.channel_pid, {:elevenlabs_transcript, :final, "ship the fix"})
      assert_push("voice", %{"session" => ^session, "kind" => "final", "text" => "ship the fix"})

      send(socket.channel_pid, {:elevenlabs_error, "ElevenLabs rejected the API key"})
      assert_push("voice_error", %{"session" => ^session, "reason" => "ElevenLabs rejected the API key"})

      send(socket.channel_pid, {:elevenlabs_closed})
      assert_push("voice_closed", %{"session" => ^session})

      # The session is released, so a late frame for it is inert.
      push(socket, "voice_audio", %{"session" => session, "audio" => "AAAA"})
      refute_receive {:voice_push, ^pid, _audio}, 50
    end

    test "a second hold replaces the first and cannot inherit its text" do
      put_endpoint_config(streamdeck_voice_session: __MODULE__.FakeVoiceSession)

      socket = joined_socket()
      assert_reply(push(socket, "voice_start", %{}), :ok, %{"session" => first})
      assert_receive {:voice_session_started, first_pid}
      first_monitor = Process.monitor(first_pid)

      # The fake emits one last transcript as it is stopped, which is exactly
      # the race a real session loses: text already in flight when the operator
      # starts a new hold.
      assert_reply(push(socket, "voice_start", %{}), :ok, %{"session" => second})
      assert_receive {:DOWN, ^first_monitor, :process, ^first_pid, _reason}
      assert second != first

      # The abandoned hold's text is not relabelled with the new session's id.
      refute_push("voice", %{"session" => ^second}, 50)
    end

    test "unfocus and channel termination stop the session, and a session crash spares the channel" do
      put_endpoint_config(streamdeck_voice_session: __MODULE__.FakeVoiceSession)

      socket = joined_socket()
      assert_reply(push(socket, "voice_start", %{}), :ok, %{"session" => _session})
      assert_receive {:voice_session_started, pid}
      monitor = Process.monitor(pid)

      assert_reply(push(socket, "unfocus", %{}), :ok, %{"focused" => nil})
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}

      assert_reply(push(socket, "voice_start", %{}), :ok, %{"session" => session})
      assert_receive {:voice_session_started, crashing_pid}
      channel_monitor = Process.monitor(socket.channel_pid)

      Process.exit(crashing_pid, :kill)

      # The device is told the hold is over…
      assert_push("voice_closed", %{"session" => ^session})
      # …and the channel is not taken down with the provider.
      refute_receive {:DOWN, ^channel_monitor, :process, _pid, _reason}, 50
    end

    test "the snapshot says whether voice is available, and never carries a key" do
      put_endpoint_config(streamdeck_voice_available_fun: fn -> false end)

      socket = authenticated_socket()
      assert {:ok, _reply, _socket} = subscribe_and_join(socket, "streamdeck:fleet")

      assert_push("snapshot", %{"voice" => voice})
      assert voice == %{"available" => false, "reason" => "Aiur has no ElevenLabs API key - transcription is off"}
    end

    test "a configured key makes voice available and states no reason" do
      put_endpoint_config(streamdeck_voice_available_fun: fn -> true end)

      # `reason` is nil rather than a description of the credential: the
      # projection reports only that one exists.
      assert StreamdeckProjection.voice() == %{available: true, reason: nil}
    end
  end

  # A voice session stands in for `Aiur.ElevenLabs.Realtime`. The seam injects
  # the session module and never a credential, so no configuration key anywhere
  # in this suite can be made to carry an API key into the channel.
  defmodule FakeVoiceSession do
    @moduledoc false
    use GenServer

    def start(opts), do: GenServer.start(__MODULE__, {Keyword.fetch!(opts, :owner), observer()})

    def push(session, audio), do: GenServer.cast(session, {:push, audio})
    def commit(session), do: GenServer.cast(session, :commit)

    @impl true
    def init({owner, observer}) do
      Process.flag(:trap_exit, true)
      send(observer, {:voice_session_started, self()})
      {:ok, %{owner: owner, observer: observer}}
    end

    @impl true
    def handle_cast({:push, audio}, state) do
      send(state.observer, {:voice_push, self(), audio})
      {:noreply, state}
    end

    def handle_cast(:commit, state) do
      send(state.observer, {:voice_commit, self()})
      {:noreply, state}
    end

    @impl true
    def terminate(_reason, state) do
      send(state.owner, {:elevenlabs_transcript, :partial, "abandoned"})
      :ok
    end

    defp observer, do: Process.whereis(:streamdeck_channel_test_observer)
  end

  defmodule UnconfiguredVoiceSession do
    @moduledoc false
    def start(_opts), do: {:error, :unconfigured}
    def push(_session, _audio), do: :ok
    def commit(_session), do: :ok
  end

  # The endpoint outlives each test, so the injected seam is removed again on
  # exit — the shared cache must not carry one test's stub into the next.
  defp put_endpoint_config(extra) do
    previous = Application.get_env(:aiur, Endpoint, [])
    config = Keyword.merge(previous, extra)

    on_exit(fn ->
      Application.put_env(:aiur, Endpoint, previous)
      # The supervised endpoint may already be down when this runs; its config
      # cache dies with it, so there is nothing left to restore.
      if Process.whereis(Endpoint), do: Endpoint.config_change([{Endpoint, previous}], [])
    end)

    Application.put_env(:aiur, Endpoint, config)
    :ok = Endpoint.config_change([{Endpoint, config}], [])
    :ok
  end

  defp joined_socket do
    socket = authenticated_socket()
    {:ok, _reply, socket} = subscribe_and_join(socket, "streamdeck:fleet")
    assert_push("snapshot", _payload)
    socket
  end

  defp authenticated_socket do
    assert {:ok, token} = StreamdeckAuth.issue_token()
    assert {:ok, socket} = StreamdeckSocket.connect(%{"token" => token}, socket(StreamdeckSocket, "authenticated", %{}), %{})
    socket
  end

  defp snapshot do
    %{agents: [AgentEvents.agent_summary("AIUR-1", :running, 0, %{title: "Channel tests"})]}
  end

  defp write_transcript(prefix, body, turn_id) do
    identifier = "#{prefix}-#{System.unique_integer([:positive])}"
    path = IssueLog.transcript_path(identifier)
    File.mkdir_p!(Path.dirname(path))
    on_exit(fn -> File.rm(path) end)

    File.write!(
      path,
      Jason.encode!(%{
        "role" => "assistant",
        "body" => body,
        "timestamp" => "2026-07-30T00:00:00Z",
        "msg_id" => "#{turn_id}-message",
        "sequence" => 1,
        "turn_id" => turn_id,
        "payload" => nil
      }) <> "\n"
    )

    identifier
  end

  # The shared event bus is a second, separate source from the transcript, so a
  # fixture that wants real event keys has to write real `[event:<kind>]` rows.
  defp write_event_log(identifier, lines) do
    path = IssueLog.event_log_path(identifier)
    File.mkdir_p!(Path.dirname(path))
    on_exit(fn -> File.rm(path) end)
    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end

  defp event_line(id, kind, topic, summary, timestamp) do
    "#{timestamp} [event:#{kind}] id=#{id} #{topic}: #{summary}"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
