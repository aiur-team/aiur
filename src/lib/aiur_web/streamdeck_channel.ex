defmodule AiurWeb.StreamdeckChannel do
  @moduledoc false
  use Phoenix.Channel

  import AiurWeb.StreamdeckChannel.CommandAnswers
  import AiurWeb.StreamdeckChannel.Voice

  alias Aiur.{AgentChat, AgentControlCLI, Commands, ProviderMeterSnapshot}
  alias Aiur.ProviderMeters.Events, as: ProviderMeterEvents
  alias AiurWeb.{Endpoint, FinancialDataAccess, StreamdeckCommands, StreamdeckLogs, StreamdeckProjection, StreamdeckTranscriptRelay}

  # One captured frame is 100 ms of 16 kHz mono s16le PCM: 3,200 bytes, or 4,272
  # base64 characters. The ceiling is set an order of magnitude above that so a
  # device that regroups differently still works, while a frame that could only
  # be a mistake or an attempt to make the channel buffer megabytes is refused
  # before it reaches the provider.
  @max_audio_frame_bytes 65_536

  @impl true
  def join(
        "streamdeck:fleet",
        _payload,
        %{
          assigns: %{
            streamdeck_authenticated: true,
            streamdeck_expires_at_ms: expires_at_ms,
            streamdeck_generation: _generation
          }
        } = socket
      ) do
    Process.flag(:message_queue_data, :off_heap)
    latch = :atomics.new(1, [])
    :ok = AiurWeb.StreamdeckFleetUpdates.subscribe(latch)
    :ok = ProviderMeterEvents.subscribe_observed()
    :ok = Commands.subscribe()
    :ok = FinancialDataAccess.subscribe_to_configuration_changes()

    send(self(), :streamdeck_snapshot)
    Process.send_after(self(), :streamdeck_auth_expired, max(expires_at_ms - System.system_time(:millisecond), 0))

    {:ok, assign(socket, focused_agent: nil, transcript_relay: nil, voice_session: nil, fleet_flush: nil, fleet_latch: latch)}
  end

  def join("streamdeck:fleet", _payload, _socket), do: {:error, %{reason: "unauthorized"}}

  @impl true
  def handle_in("focus", %{"identifier" => identifier}, socket)
      when is_binary(identifier) and byte_size(identifier) in 1..200 do
    # Leaving the agent ends the hold with it: a dictation belongs to the agent
    # it was started on, so it must not follow focus to another one.
    socket = socket |> stop_voice_session() |> unsubscribe_focused()
    {:ok, relay} = StreamdeckTranscriptRelay.start_link(self(), identifier, transcript_flush_ms())

    socket = assign(socket, focused_agent: identifier, transcript_relay: relay)
    push(socket, "logs", logs_projection(identifier))
    push(socket, "commands", commands_projection(identifier))
    {:reply, {:ok, %{"focused" => identifier}}, socket}
  end

  def handle_in("focus", _payload, socket), do: {:reply, {:error, %{reason: "invalid_identifier"}}, socket}

  def handle_in("unfocus", _payload, socket) do
    {:reply, {:ok, %{"focused" => nil}}, socket |> stop_voice_session() |> unsubscribe_focused()}
  end

  @doc """
  Routes a physical key toggle through the same AgentChat facade as the emulator.

  Pause and resume are the action set for a ticket an agent already holds. The
  deck's agent view no longer carries a prioritize key — its slots are pause,
  logs, mic and settings — so the channel does not accept an action no surface
  can send. Orchestrator priority itself is untouched and stays reachable from
  the dashboard.

  `implement` is the third action, and it belongs to the other half of the grid:
  a ticket with **no** agent, whose command surface offers Implement where a
  live agent offers Pause. See `handle_in("control", %{"action" => "implement"})`
  below for why it goes through the CLI's own queue path.
  """

  def handle_in("control", %{"identifier" => identifier, "action" => action}, socket)
      when is_binary(identifier) and byte_size(identifier) in 1..200 and action in ["pause", "resume"] do
    result =
      case action do
        "pause" -> pause_agent(identifier)
        "resume" -> AgentChat.resume(identifier)
      end

    case result do
      {:ok, value} -> {:reply, {:ok, %{"identifier" => identifier, "action" => action, "result" => value}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: reason_text(reason)}}, socket}
    end
  end

  # Queues a ticket that has no agent, which is what the deck's Implement key
  # asks for.
  #
  # The label is never written here. `Aiur.AgentControlCLI.todo/2` is the same
  # function the CLI's `aiur --todo <ids>` command calls (`Aiur.CLI`), and it
  # owns rules a raw label write does not have: it refuses a closed or otherwise
  # terminal ticket, leaves a ticket that is already mid-flight alone, is
  # idempotent for a ticket already carrying the queue label, resolves the
  # *configured* lifecycle label rather than assuming `agent:todo`, and asks the
  # orchestrator to refresh so the queue is seen without waiting for the next
  # poll. Duplicating any of that here would be a second, weaker way to queue a
  # ticket — and the two would drift.
  #
  # It reports through stdout like every other CLI command, so a deck press is
  # visible in the daemon's log exactly as the equivalent typed command is.
  def handle_in("control", %{"identifier" => identifier, "action" => "implement"}, %{assigns: %{streamdeck_authenticated: true}} = socket)
      when is_binary(identifier) and byte_size(identifier) in 1..200 do
    case queue_ticket(identifier) do
      :ok -> {:reply, {:ok, %{"identifier" => identifier, "action" => "implement", "result" => "queued"}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: reason_text(reason)}}, socket}
    end
  end

  def handle_in("control", %{"action" => "implement"}, %{assigns: %{streamdeck_authenticated: true}} = socket),
    do: {:reply, {:error, %{reason: "invalid_control"}}, socket}

  # Unauthorised sockets are answered the way `say` answers them, rather than
  # with the generic `invalid_control`: a device whose credentials lapsed must be
  # told that, not told its payload was malformed.
  def handle_in("control", %{"action" => "implement"}, socket),
    do: {:reply, {:error, %{reason: "unauthorized"}}, socket}

  def handle_in("control", _payload, socket), do: {:reply, {:error, %{reason: "invalid_control"}}, socket}

  # The Commands page pages through the focused agent's history with an opaque
  # server cursor, so a device that reconnects mid-scroll resumes where it was
  # without the client ever interpreting the store's cursor encoding.
  def handle_in("commands_page", %{"cursor" => cursor}, %{assigns: %{focused_agent: identifier}} = socket)
      when is_binary(identifier) and is_binary(cursor) and cursor != "" do
    case StreamdeckCommands.history(identifier, cursor, store: command_store(socket)) do
      {:ok, page} -> {:reply, {:ok, Map.put(page, "identifier", identifier)}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: reason_text(reason)}}, socket}
    end
  end

  def handle_in("commands_page", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_commands_page"}}, socket}

  # Records an operator answer given on the device.
  #
  # Attribution is the load-bearing decision: the operator physically pressing
  # their own deck is the operator answering, so the durable record carries an
  # `%{kind: :operator, id: "streamdeck"}` actor — never an Executor answer with
  # an operator flavour. That is what lets the device answer `human_required`
  # Commands the Executor cannot, while the dashboard shows a true operator
  # answer. The device may only answer a Command for the agent it is currently
  # focused on (focused-ticket enforcement), and it answers the exact `version`
  # it read, so a retry after a dropped reply is an idempotent replay of the
  # durable action rather than a second decision.
  def handle_in(
        "answer_command",
        %{"decision_id" => decision_id, "idempotency_key" => idempotency_key, "version" => version} = payload,
        %{assigns: %{focused_agent: identifier}} = socket
      )
      when is_binary(identifier) and is_binary(decision_id) and decision_id != "" and
             is_binary(idempotency_key) and idempotency_key != "" and is_integer(version) and version > 0 do
    with {:ok, answer} <- build_answer_payload(payload),
         :ok <- validate_focused_command(socket, decision_id, identifier, version),
         {:ok, result} <- record_command_answer(decision_id, answer) do
      {:reply, {:ok, answer_result(result)}, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: reason_text(reason)}}, socket}
    end
  end

  def handle_in("answer_command", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_answer"}}, socket}

  # Delivers a spoken (device-transcribed) message to an agent through the same
  # `AgentChat.send/2` facade the dashboard chat box uses, so voice and typed
  # input share one delivery path. Admission is not shared: a device cannot show
  # a deep failure, so this channel trims the text and refuses an empty or
  # over-long dictation up front (see `validate_message/1`), which the dashboard
  # chat box does not do.
  def handle_in("say", %{"identifier" => identifier, "text" => text} = payload, %{assigns: %{streamdeck_authenticated: true}} = socket)
      when is_binary(identifier) and byte_size(identifier) in 1..200 and is_binary(text) do
    case validate_message(String.trim(text)) do
      {:ok, message} -> reply_to_say(identifier, message, say_message_id(payload), socket)
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("say", _payload, %{assigns: %{streamdeck_authenticated: true}} = socket),
    do: {:reply, {:error, %{reason: "invalid_message"}}, socket}

  def handle_in("say", _payload, socket), do: {:reply, {:error, %{reason: "unauthorized"}}, socket}

  # Voice input: the device streams captured audio here and Aiur performs the
  # ElevenLabs call, so `ELEVENLABS_API_KEY` never exists in the sidecar. Audio
  # arrives as the base64 string the provider's own frame wants, so this channel
  # relays it verbatim and transcodes nothing.
  def handle_in("voice_start", _payload, %{assigns: %{streamdeck_authenticated: true}} = socket) do
    # A second hold replaces the first rather than racing it, and the replaced
    # session is stopped before a new one exists so nothing it already emitted
    # can be relabelled with the new session id.
    socket = stop_voice_session(socket)

    case open_voice_session() do
      {:ok, session} -> {:reply, {:ok, %{"session" => session.id}}, assign(socket, :voice_session, session)}
      {:error, reason} -> {:reply, {:error, %{"reason" => reason_text(reason)}}, socket}
    end
  end

  def handle_in("voice_start", _payload, socket), do: {:reply, {:error, %{"reason" => "unauthorized"}}, socket}

  # The repeated `session` binding is the whole stale-frame guard: a frame from a
  # previous hold cannot match the live session and therefore cannot reach the
  # provider.
  def handle_in("voice_audio", %{"session" => session, "audio" => audio}, %{assigns: %{voice_session: %{id: session, pid: pid, module: module}}} = socket)
      when is_binary(audio) and byte_size(audio) <= @max_audio_frame_bytes do
    :ok = module.push(pid, audio)
    {:noreply, socket}
  end

  # An unknown session, an oversized frame or a malformed payload is dropped in
  # silence. A device that has already moved on must not be answered, and must
  # not be able to crash the channel either.
  def handle_in("voice_audio", _payload, socket), do: {:noreply, socket}

  def handle_in("voice_stop", %{"session" => session}, %{assigns: %{voice_session: %{id: session, pid: pid, module: module}}} = socket) do
    # Commit rather than kill: the documented commit flush is what settles the
    # tail of the utterance, and the session closes itself once it arrives.
    :ok = module.commit(pid)
    {:reply, {:ok, %{}}, socket}
  end

  # A stop for a session that is already gone is the ordinary end of a hold, not
  # an error, so it is acknowledged and does nothing.
  def handle_in("voice_stop", _payload, socket), do: {:reply, {:ok, %{}}, socket}

  @impl true
  def handle_info(:streamdeck_snapshot, socket) do
    push(socket, "snapshot", StreamdeckProjection.snapshot())
    {:noreply, socket}
  end

  def handle_info(:streamdeck_auth_expired, socket), do: {:stop, :normal, socket}

  def handle_info({FinancialDataAccess, :configuration_changed, generation}, %{assigns: %{streamdeck_generation: generation}} = socket),
    do: {:noreply, socket}

  def handle_info({FinancialDataAccess, :configuration_changed, _generation}, socket), do: {:stop, :normal, socket}

  def handle_info(:fleet_changed, socket), do: AiurWeb.StreamdeckFleetUpdates.schedule(socket)
  def handle_info({:flush_fleet, token}, socket), do: AiurWeb.StreamdeckFleetUpdates.flush(socket, token)

  def handle_info({:provider_meter_changed, %ProviderMeterSnapshot{} = snapshot}, socket) do
    push(socket, "usage", StreamdeckProjection.provider_meters(snapshot))
    {:noreply, socket}
  end

  def handle_info({:decision_changed, decision_id, _version}, %{assigns: %{focused_agent: identifier}} = socket)
      when is_binary(identifier) do
    # `push/3` returns `:ok`, not a socket: rebinding `socket` from it would
    # poison the type for the next push below. Call it for its side effect and
    # keep the original socket, exactly like `push_decisions/1`.
    push(socket, "decisions", StreamdeckProjection.decisions())

    if focused_command?(socket, decision_id, identifier) do
      push(socket, "commands", commands_projection(identifier))
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:decision_changed, _decision_id, _version}, socket), do: push_decisions(socket)
  def handle_info(:decision_metrics_changed, socket), do: push_decisions(socket)

  def handle_info({:streamdeck_transcript, identifier, event}, %{assigns: %{focused_agent: identifier}} = socket) do
    push(socket, "transcript", StreamdeckProjection.transcript(identifier, event))
    push(socket, "logs", logs_projection(identifier))
    {:noreply, socket}
  end

  def handle_info({:streamdeck_alert, identifier, event}, %{assigns: %{focused_agent: identifier}} = socket) do
    push(socket, "alert", StreamdeckProjection.alert(identifier, event))
    {:noreply, socket}
  end

  def handle_info({:streamdeck_control, identifier, payload}, %{assigns: %{focused_agent: identifier}} = socket) do
    push(socket, "control", StreamdeckProjection.control(identifier, payload))
    {:noreply, socket}
  end

  def handle_info({:elevenlabs_transcript, kind, text}, %{assigns: %{voice_session: %{id: session}}} = socket)
      when kind in [:partial, :final] and is_binary(text) do
    push(socket, "voice", %{"session" => session, "kind" => Atom.to_string(kind), "text" => text})
    {:noreply, socket}
  end

  def handle_info({:elevenlabs_error, reason}, %{assigns: %{voice_session: %{id: session}}} = socket) do
    push(socket, "voice_error", %{"session" => session, "reason" => reason_text(reason)})
    {:noreply, socket}
  end

  def handle_info({:elevenlabs_closed}, %{assigns: %{voice_session: %{id: session, ref: ref}}} = socket) do
    Process.demonitor(ref, [:flush])
    push(socket, "voice_closed", %{"session" => session})
    {:noreply, assign(socket, :voice_session, nil)}
  end

  # The session died without announcing it. The device is told the hold is over
  # rather than being left waiting on text that is never coming.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{assigns: %{voice_session: %{id: session, ref: ref}}} = socket) do
    push(socket, "voice_closed", %{"session" => session})
    {:noreply, assign(socket, :voice_session, nil)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    socket |> assigns() |> Map.get(:transcript_relay) |> stop_child()
    socket |> assigns() |> Map.get(:voice_session) |> voice_pid() |> stop_child()
    :ok
  end

  defp assigns(%{assigns: assigns}) when is_map(assigns), do: assigns
  defp assigns(_socket), do: %{}

  defp voice_pid(%{pid: pid}), do: pid
  defp voice_pid(_session), do: nil

  defp reply_to_say(identifier, message, message_id, socket) do
    case send_agent_message(identifier, message, message_id) do
      {:ok, request_id} -> {:reply, {:ok, %{"request_id" => request_id}}, socket}
      {:error, {:outcome_unknown, _info}} -> {:reply, {:error, %{reason: "outcome_unknown"}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: reason_text(reason)}}, socket}
    end
  end

  # Atom/binary reasons (`:no_agent`, `:message_too_long`) render as the bare
  # word the device shows; anything structured falls back to `inspect/1` rather
  # than raising a String.Chars error inside the reply.
  # One queue attempt, through the CLI's own todo path. The seam is the function,
  # not the tracker: a test supplies its own queue function and no configuration
  # can make this channel reach GitHub.
  defp queue_ticket(identifier) do
    case queue_ticket_fun().(identifier) do
      :ok -> :ok
      0 -> :ok
      1 -> {:error, :queue_failed}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :queue_failed}
    end
  rescue
    error -> {:error, {:queue_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:queue_unavailable, reason}}
  end

  defp queue_ticket_fun do
    case Endpoint.config(:streamdeck_implement_fun) do
      fun when is_function(fun, 1) -> fun
      _absent -> fn identifier -> AgentControlCLI.todo([identifier]) end
    end
  end

  defp reason_text(reason) when is_atom(reason) or is_binary(reason), do: to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  defp pause_agent(identifier) do
    case Endpoint.config(:agent_chat_pause_fun) do
      fun when is_function(fun, 1) -> fun.(identifier)
      _fun -> AgentChat.pause(identifier)
    end
  end

  defp push_decisions(socket) do
    push(socket, "decisions", StreamdeckProjection.decisions())
    {:noreply, socket}
  end

  defp unsubscribe_focused(%{assigns: %{transcript_relay: relay}} = socket) when is_pid(relay) do
    :ok = GenServer.stop(relay, :normal)
    assign(socket, focused_agent: nil, transcript_relay: nil)
  end

  defp unsubscribe_focused(socket), do: socket

  defp transcript_flush_ms do
    Endpoint.config(:streamdeck_transcript_flush_ms) ||
      Application.get_env(:aiur, Endpoint, []) |> Keyword.get(:streamdeck_transcript_flush_ms) || 250
  end

  defp logs_projection(identifier) do
    identifier |> StreamdeckLogs.load() |> StreamdeckLogs.wire()
  end
end
