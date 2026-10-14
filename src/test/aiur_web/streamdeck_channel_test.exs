defmodule AiurWeb.StreamdeckChannelTest do
  use AiurWeb.StreamdeckChannelCase

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
end
