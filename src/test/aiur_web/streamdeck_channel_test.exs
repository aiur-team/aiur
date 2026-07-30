defmodule AiurWeb.StreamdeckChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  alias Aiur.AgentEvents
  alias Aiur.AgentPubSub
  alias Aiur.ProviderMeters.Events, as: ProviderMeterEvents
  alias Aiur.ProviderMeterSnapshot
  alias AiurWeb.{Endpoint, StreamdeckAuth, StreamdeckProjection, StreamdeckSocket}

  @endpoint Endpoint

  setup do
    original_config = Application.get_env(:aiur, Endpoint, [])
    original_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    original_password = System.get_env("AIUR_DASHBOARD_PASSWORD")

    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")

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

    if is_nil(Process.whereis(Endpoint)) do
      start_supervised!({Endpoint, []})
    else
      Endpoint.config_change(config, [])
    end

    on_exit(fn ->
      Application.put_env(:aiur, Endpoint, original_config)
      restore_env("AIUR_DASHBOARD_USERNAME", original_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", original_password)
    end)

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

  test "socket tokens are invalidated when dashboard credentials change" do
    assert {:ok, token} = StreamdeckAuth.issue_token()

    System.put_env("AIUR_DASHBOARD_PASSWORD", "rotated-secret")

    assert :error = StreamdeckAuth.verify_token(token)
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
    assert %{"error" => %{"code" => "authentication_required"}} = Jason.decode!(response.resp_body)
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

    assert_push("fleet", %{"agents" => [%{"identifier" => "AIUR-2", "status" => "running", "title" => "Pushed"}]})
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
    ProviderMeterEvents.broadcast(ProviderMeterSnapshot.empty(:codex, :app_server, "streamdeck-test-generation"))

    assert_push("usage", %{"claude" => %{"state" => "unknown"}, "codex" => %{"state" => "observed"}})
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

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
