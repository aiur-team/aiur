defmodule AiurWeb.StreamdeckChannel do
  @moduledoc false

  use Phoenix.Channel

  alias Aiur.{AgentChat, AgentPubSub, DecisionPubSub, ProviderMeterSnapshot}
  alias Aiur.ProviderMeters.Events, as: ProviderMeterEvents
  alias AiurWeb.{Endpoint, FinancialDataAccess, StreamdeckLogs, StreamdeckProjection, StreamdeckTranscriptRelay}

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

    {:ok, assign(socket, focused_agent: nil, transcript_relay: nil)}
  end

  def join("streamdeck:fleet", _payload, _socket), do: {:error, %{reason: "unauthorized"}}

  @impl true
  def handle_in("focus", %{"identifier" => identifier}, socket)
      when is_binary(identifier) and byte_size(identifier) in 1..200 do
    socket = unsubscribe_focused(socket)
    {:ok, relay} = StreamdeckTranscriptRelay.start_link(self(), identifier, transcript_flush_ms())

    socket = assign(socket, focused_agent: identifier, transcript_relay: relay)
    push(socket, "logs", logs_projection(identifier))
    {:reply, {:ok, %{"focused" => identifier}}, socket}
  end

  def handle_in("focus", _payload, socket), do: {:reply, {:error, %{reason: "invalid_identifier"}}, socket}

  def handle_in("unfocus", _payload, socket) do
    {:reply, {:ok, %{"focused" => nil}}, unsubscribe_focused(socket)}
  end

  @doc "Routes a physical key toggle through the same AgentChat facade as the emulator."
  def handle_in("control", %{"identifier" => identifier, "action" => action}, socket)
      when is_binary(identifier) and byte_size(identifier) in 1..200 and action in ["pause", "resume", "prioritize", "deprioritize"] do
    result =
      case action do
        "pause" -> AgentChat.pause(identifier)
        "resume" -> AgentChat.resume(identifier)
        "prioritize" -> AgentChat.prioritize(identifier)
        "deprioritize" -> AgentChat.deprioritize(identifier)
      end

    case result do
      {:ok, value} -> {:reply, {:ok, %{"identifier" => identifier, "action" => action, "result" => value}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("control", _payload, socket), do: {:reply, {:error, %{reason: "invalid_control"}}, socket}

  # Delivers a spoken (device-transcribed) message to an agent through the same
  # `AgentChat.send/2` facade the dashboard chat box uses, so voice and typed
  # input share one delivery path, one audit trail, and one set of orchestrator
  # rules.
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

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, %{assigns: %{transcript_relay: relay}}) when is_pid(relay) do
    :ok = GenServer.stop(relay, :normal)
    :ok
  end

  def terminate(_reason, _socket), do: :ok

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
      {:ok, request_id} -> {:reply, {:ok, %{request_id: request_id}}, socket}
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
end
