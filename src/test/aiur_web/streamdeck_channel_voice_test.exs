defmodule AiurWeb.StreamdeckChannelVoiceTest do
  use AiurWeb.StreamdeckChannelCase

  describe "control: implement" do
    test "queues the ticket through the CLI todo seam and reports it queued" do
      test_pid = self()
      put_endpoint_config(streamdeck_implement_fun: fn identifier -> send(test_pid, {:queued, identifier}) && 0 end)

      socket = joined_socket()
      implement = push(socket, "control", %{"identifier" => "AIUR-1", "action" => "implement"})

      assert_reply(implement, :ok, %{"identifier" => "AIUR-1", "action" => "implement", "result" => "queued"})
      assert_received {:queued, "AIUR-1"}
    end

    test "reports a ticket that cannot be queued as an error rather than a silent success" do
      # `Aiur.AgentControlCLI.todo/2` answers with the CLI's own exit code: 1 is
      # a ticket it refused (closed, terminal, or a failed label write).
      put_endpoint_config(streamdeck_implement_fun: fn _identifier -> 1 end)

      socket = joined_socket()
      implement = push(socket, "control", %{"identifier" => "AIUR-1", "action" => "implement"})

      assert_reply(implement, :error, %{reason: "queue_failed"})
    end

    test "reports a queue path that raises as an error instead of taking the channel down" do
      put_endpoint_config(streamdeck_implement_fun: fn _identifier -> raise "tracker unreachable" end)

      socket = joined_socket()
      implement = push(socket, "control", %{"identifier" => "AIUR-1", "action" => "implement"})

      assert_reply(implement, :error, %{reason: reason})
      assert reason =~ "queue_failed"
    end

    test "rejects a malformed implement payload without queueing anything" do
      test_pid = self()
      put_endpoint_config(streamdeck_implement_fun: fn identifier -> send(test_pid, {:queued, identifier}) && 0 end)

      socket = joined_socket()

      for payload <- [%{"action" => "implement"}, %{"identifier" => "", "action" => "implement"}, %{"identifier" => 7, "action" => "implement"}] do
        assert_reply(push(socket, "control", payload), :error, %{reason: "invalid_control"})
      end

      refute_received {:queued, _identifier}
    end

    test "rejects an unauthenticated socket the way say does" do
      unauthenticated = %Phoenix.Socket{assigns: %{streamdeck_authenticated: false}}

      assert {:reply, {:error, %{reason: "unauthorized"}}, ^unauthenticated} =
               StreamdeckChannel.handle_in("control", %{"identifier" => "AIUR-1", "action" => "implement"}, unauthenticated)
    end
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

    # #2717. The sidecar sends one id per say press; the channel passes it on
    # so a re-sent frame cannot queue a copy, and an unknown outcome is named.
    test "passes the say press message id to delivery and names an unknown outcome" do
      test_pid = self()

      put_endpoint_config(
        agent_chat_send_fun: fn identifier, text, opts ->
          send(test_pid, {:sent, identifier, text, Keyword.fetch!(opts, :message_id)})
          {:error, {:outcome_unknown, %{message_id: Keyword.fetch!(opts, :message_id), item_id: nil}}}
        end
      )

      socket = joined_socket()
      say = push(socket, "say", %{"identifier" => "AIUR-1", "text" => "continue", "message_id" => "press-1"})

      assert_reply(say, :error, %{reason: "outcome_unknown"})
      assert_received {:sent, "AIUR-1", "continue", "press-1"}

      plain = push(socket, "say", %{"identifier" => "AIUR-1", "text" => "continue"})
      assert_reply(plain, :error, %{reason: "outcome_unknown"})
      assert_received {:sent, "AIUR-1", "continue", nil}
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

      assert_receive {:voice_session_started, pid}, 1000

      push(socket, "voice_audio", %{"session" => session, "audio" => "Zm9vYmFy"})
      # Relayed exactly, because the provider's own frame wants this string.
      assert_receive {:voice_push, ^pid, "Zm9vYmFy"}, 1000

      stop = push(socket, "voice_stop", %{"session" => session})
      assert_reply(stop, :ok, %{})
      # Stop commits the utterance rather than killing it; the commit flush is
      # what settles the tail of what was just said.
      assert_receive {:voice_commit, ^pid}, 1000
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
      assert_receive {:voice_session_started, pid}, 1000

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
      assert_receive {:voice_push, ^pid, "AAAA"}, 1000
    end

    test "transcripts, errors and closure reach the device tagged with their session" do
      put_endpoint_config(streamdeck_voice_session: __MODULE__.FakeVoiceSession)

      socket = joined_socket()
      assert_reply(push(socket, "voice_start", %{}), :ok, %{"session" => session})
      assert_receive {:voice_session_started, pid}, 1000

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
      assert_receive {:voice_session_started, first_pid}, 1000
      first_monitor = Process.monitor(first_pid)

      # The fake emits one last transcript as it is stopped, which is exactly
      # the race a real session loses: text already in flight when the operator
      # starts a new hold.
      assert_reply(push(socket, "voice_start", %{}), :ok, %{"session" => second})
      assert_receive {:DOWN, ^first_monitor, :process, ^first_pid, _reason}, 1000
      assert second != first

      # The abandoned hold's text is not relabelled with the new session's id.
      refute_push("voice", %{"session" => ^second}, 50)
    end

    test "unfocus and channel termination stop the session, and a session crash spares the channel" do
      put_endpoint_config(streamdeck_voice_session: __MODULE__.FakeVoiceSession)

      socket = joined_socket()
      assert_reply(push(socket, "voice_start", %{}), :ok, %{"session" => _session})
      assert_receive {:voice_session_started, pid}, 1000
      monitor = Process.monitor(pid)

      assert_reply(push(socket, "unfocus", %{}), :ok, %{"focused" => nil})
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1000

      assert_reply(push(socket, "voice_start", %{}), :ok, %{"session" => session})
      assert_receive {:voice_session_started, crashing_pid}, 1000
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
end
