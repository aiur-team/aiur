defmodule AiurWeb.StreamdeckChannel do
  @moduledoc false

  use Phoenix.Channel

  alias Aiur.{AgentChat, AgentPubSub, DecisionPubSub, ProviderMeterSnapshot}
  alias Aiur.ElevenLabs.Realtime
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
    :ok = AgentPubSub.subscribe_running()
    :ok = AgentPubSub.subscribe_status()
    :ok = ProviderMeterEvents.subscribe_observed()
    :ok = DecisionPubSub.subscribe()
    :ok = FinancialDataAccess.subscribe_to_configuration_changes()

    send(self(), :streamdeck_snapshot)
    Process.send_after(self(), :streamdeck_auth_expired, max(expires_at_ms - System.system_time(:millisecond), 0))

    {:ok, assign(socket, focused_agent: nil, transcript_relay: nil, voice_session: nil)}
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

  Pause and resume are the whole action set. The deck's agent view no longer
  carries a prioritize key — its four slots are pause, logs, mic and settings —
  so the channel no longer accepts an action no surface can send. Orchestrator
  priority itself is untouched and stays reachable from the dashboard.
  """
  def handle_in("control", %{"identifier" => identifier, "action" => action}, socket)
      when is_binary(identifier) and byte_size(identifier) in 1..200 and action in ["pause", "resume"] do
    result =
      case action do
        "pause" -> AgentChat.pause(identifier)
        "resume" -> AgentChat.resume(identifier)
      end

    case result do
      {:ok, value} -> {:reply, {:ok, %{"identifier" => identifier, "action" => action, "result" => value}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: reason_text(reason)}}, socket}
    end
  end

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
  def handle_in("say", %{"identifier" => identifier, "text" => text}, %{assigns: %{streamdeck_authenticated: true}} = socket)
      when is_binary(identifier) and byte_size(identifier) in 1..200 and is_binary(text) do
    case validate_message(String.trim(text)) do
      {:ok, message} -> reply_to_say(identifier, message, socket)
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
    push(socket, "snapshot", StreamdeckProjection.snapshot() |> Map.put("grid", StreamdeckProjection.grid()))
    {:noreply, socket}
  end

  def handle_info(:streamdeck_auth_expired, socket), do: {:stop, :normal, socket}

  def handle_info({FinancialDataAccess, :configuration_changed, generation}, %{assigns: %{streamdeck_generation: generation}} = socket),
    do: {:noreply, socket}

  def handle_info({FinancialDataAccess, :configuration_changed, _generation}, socket), do: {:stop, :normal, socket}

  def handle_info({:running_changed, summaries}, socket) when is_list(summaries) do
    push(
      socket,
      "fleet",
      StreamdeckProjection.fleet()
      |> Map.put("agents", StreamdeckProjection.fleet_agents(summaries))
      |> Map.put("grid", StreamdeckProjection.grid())
    )

    {:noreply, socket}
  end

  # `agents:status` carries agent-list pane visibility (for example
  # `:pane_opened`), not the fleet status named by this channel's public
  # contract. Translate it to a fresh fleet projection instead of leaking the
  # implementation detail to devices.
  def handle_info({:status_changed, %{identifier: _identifier, status: _status}}, socket) do
    push(socket, "fleet", StreamdeckProjection.fleet() |> Map.put("grid", StreamdeckProjection.grid()))
    {:noreply, socket}
  end

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

  defp stop_child(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  defp stop_child(_absent), do: :ok

  # The session module is the seam, never the credential: a test supplies a fake
  # session and no configuration anywhere can be made to carry an API key into
  # this channel.
  defp voice_session_module do
    case Endpoint.config(:streamdeck_voice_session) do
      module when is_atom(module) and not is_nil(module) -> module
      _absent -> Realtime
    end
  end

  defp open_voice_session do
    module = voice_session_module()

    case module.start(owner: self()) do
      # The module is remembered with the session rather than re-read per frame,
      # so a configuration change cannot leave `push` and `commit` addressing a
      # different implementation than the one that opened the connection.
      {:ok, pid} -> {:ok, %{id: mint_session_id(), pid: pid, ref: Process.monitor(pid), module: module}}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :voice_unavailable}
    end
  end

  # Opaque and server-minted, so a device cannot address a session it did not
  # open and a replayed id from a previous hold cannot collide with a live one.
  defp mint_session_id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp stop_voice_session(%{assigns: %{voice_session: %{pid: pid, ref: ref}}} = socket) do
    Process.demonitor(ref, [:flush])
    stop_child(pid)
    # `GenServer.stop/2` is synchronous, so everything the stopped session ever
    # sent is already in this mailbox. Draining it here is what stops a transcript
    # from the abandoned hold being pushed under the next session's id.
    drain_voice_messages()
    assign(socket, :voice_session, nil)
  end

  defp stop_voice_session(socket), do: socket

  defp drain_voice_messages do
    receive do
      {:elevenlabs_transcript, _kind, _text} -> drain_voice_messages()
      {:elevenlabs_error, _reason} -> drain_voice_messages()
      {:elevenlabs_closed} -> drain_voice_messages()
    after
      0 -> :ok
    end
  end

  # Mirrors `Aiur.Orchestrator.OperatorMessages`' own ceiling so an over-long
  # dictation is refused here, with a reason the device can show, instead of
  # failing deeper in delivery.
  @max_message_chars 8_000

  defp validate_message(""), do: {:error, "empty_message"}

  defp validate_message(message) do
    if String.length(message) > @max_message_chars do
      {:error, "message_too_long"}
    else
      {:ok, message}
    end
  end

  defp reply_to_say(identifier, message, socket) do
    case send_agent_message(identifier, message) do
      {:ok, request_id} -> {:reply, {:ok, %{"request_id" => request_id}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: reason_text(reason)}}, socket}
    end
  end

  # Atom/binary reasons (`:no_agent`, `:message_too_long`) render as the bare
  # word the device shows; anything structured falls back to `inspect/1` rather
  # than raising a String.Chars error inside the reply.
  defp reason_text(reason) when is_atom(reason) or is_binary(reason), do: to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  # Same injection seam as the dashboard's chat box (`DashboardLive`), so tests
  # can observe delivery without a live orchestrator.
  defp send_agent_message(identifier, message) do
    case Endpoint.config(:agent_chat_send_fun) do
      fun when is_function(fun, 2) -> fun.(identifier, message)
      _fun -> AgentChat.send(identifier, message)
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

  # The focused agent's Commands page. An unreadable store is projected as
  # explicitly unavailable rather than as an empty history, so the device says
  # "Commands unavailable" instead of silently showing no Commands for an agent
  # that has them. It reads through the same endpoint-configured store as the
  # interactive `commands_page`/`answer_command` handlers, so a configured
  # (or injected) store is honoured on the focus push too.
  defp commands_projection(identifier) do
    case StreamdeckCommands.history(identifier, nil, store: command_store()) do
      {:ok, page} -> Map.put(page, "identifier", identifier)
      {:error, _reason} -> %{"identifier" => identifier, "unavailable" => true}
    end
  end

  # A `decision_changed` broadcast carries only the decision id; the focused
  # Command surface must be refreshed only when that decision belongs to the
  # agent being watched, so the device is not repainted for every Command in
  # the fleet. On an error the page repaints anyway (fail-open): skipping a
  # repaint would silently freeze a stale Commands page with no later event to
  # refresh it, while `commands_projection/1` already surfaces an unreadable
  # store as an explicit "unavailable" page.
  defp focused_command?(socket, decision_id, identifier) do
    case StreamdeckCommands.detail(decision_id, store: command_store(socket)) do
      {:ok, item} -> get_in(item, ["ticket", "identifier"]) == identifier
      {:error, _reason} -> true
    end
  rescue
    _error -> true
  catch
    _kind, _reason -> true
  end

  # The device may only answer a Command that belongs to the agent it is
  # currently focused on, and only the exact version it read. Fetching the
  # decision here both enforces the boundary and lets the store's replay
  # semantics decide duplicate-versus-conflict for a retried answer.
  defp validate_focused_command(socket, decision_id, identifier, version) do
    case StreamdeckCommands.detail(decision_id, store: command_store(socket)) do
      {:ok, item} ->
        cond do
          get_in(item, ["ticket", "identifier"]) != identifier ->
            {:error, :command_not_focused}

          Map.get(item, "version") != version ->
            {:error, {:stale_version, version, Map.get(item, "version")}}

          # Only open and deferred Commands are answerable, allowlisted rather
          # than blocklisted: every newly-added terminal status would otherwise
          # silently become answerable the moment it exists. The TS client
          # renders the same two statuses as answerable (`commands.ts`), so
          # client and server agree on what "answerable" means.
          Map.get(item, "status") not in ["open", "deferred"] ->
            {:error, {:not_answerable, Map.get(item, "status")}}

          true ->
            :ok
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_command_answer(decision_id, answer) do
    store = command_store()
    actor = StreamdeckCommands.actor()

    # `store` is the decision server — a module or a pid — so the answer must
    # go through `Aiur.DecisionStore.answer/5` with the server passed as the
    # fourth argument, exactly as the dashboard's decision commands do. Calling
    # `store.answer/4` would `apply/3` a pid as a module and fail.
    case Aiur.DecisionStore.answer(decision_id, answer, [actor: actor], store) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:answer_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  defp answer_result(%{status: status, decision: decision}) do
    %{"status" => Atom.to_string(status), "decision" => StreamdeckCommands.item(decision)}
  end

  defp answer_result(result), do: result

  # Exactly one of option_id or custom_response, mirroring the CLI's
  # `executor-answer --option|--custom-response` contract so the custom-response
  # path maps onto an already-supported operation.
  defp build_answer_payload(%{"option_id" => option_id, "version" => version, "idempotency_key" => key})
       when is_binary(option_id) and option_id != "" do
    {:ok, %{"idempotency_key" => key, "expected_version" => version, "option_id" => option_id}}
  end

  defp build_answer_payload(%{"custom_response" => text, "version" => version, "idempotency_key" => key})
       when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :empty_custom_response}
      text -> {:ok, %{"idempotency_key" => key, "expected_version" => version, "custom_response" => text}}
    end
  end

  defp build_answer_payload(_payload), do: {:error, :invalid_answer}

  defp command_store(_socket), do: command_store()
  defp command_store, do: Endpoint.config(:decision_store) || Aiur.DecisionStore
end
