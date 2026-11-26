defmodule AiurWeb.Build.Composer do
  @moduledoc """
  The build modal's composer: sends an Executor message to the open ticket's
  running agent through `OperatorSend` (the drawer's path) and reports what
  became of it with a bounded delivery poll.

  The client names only the ticket; the target is the open conversation's
  composer. "delivered" is pushed only from a `:delivered`/`:consumed` read;
  a timeout, an unreadable status or an exhausted poll is "unconfirmed".
  """
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, start_async: 3]
  alias Aiur.Voice
  alias AiurWeb.Build.{Payload, URLState}
  alias AiurWeb.EndpointConfig
  alias AiurWeb.OperatorControlCenter.{AgentLogModal, OperatorSend}

  @delays_ms [500, 1_000, 2_000, 4_000, 8_000, 15_000, 30_000]
  @status_timeout_ms 1_000
  @tags ~w(no_running_agent empty_message message_too_long max_concurrent_agents_reached globally_paused unavailable timeout ambiguous_identifier)a
  @unmapped_copy "Send failed. Check the log before you send again."
  @voice_not_installed "Voice input isn't installed in this Aiur. Typed messages work as usual."
  @voice_unconfigured "ElevenLabs speech-to-text is not configured. Dictation is unavailable; ask the Executor to run `aiur init` and add an ElevenLabs API key."

  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket), do: assign(socket, send_pending: %{}, send_tracking: %{}, send_queued: MapSet.new())

  @spec voice_availability() :: %{optional(:reason) => String.t(), state: String.t()}
  def voice_availability do
    if EndpointConfig.get(:dashboard_writable) == true do
      case Voice.availability() do
        %{available: true} -> %{state: "available"}
        %{reason: :unconfigured} -> %{state: "unconfigured", reason: @voice_unconfigured}
        %{reason: :not_installed} -> %{state: "unconfigured", reason: @voice_not_installed}
      end
    else
      %{state: "read_only", reason: "Read-only dashboard — dictation is off."}
    end
  end

  @spec send(Phoenix.LiveView.Socket.t(), map()) :: {:reply, map(), Phoenix.LiveView.Socket.t()}
  def send(socket, %{"id" => id, "text" => text}) when is_binary(id) and is_binary(text) do
    cond do
      URLState.parse(%{"ticket" => id}).ticket != id -> {:reply, Payload.error(:invalid_params), socket}
      not (socket.assigns.writable and EndpointConfig.get(:dashboard_writable) == true) -> {:reply, Payload.error(:read_only), assign(socket, :writable, false)}
      true -> send_to(socket, id, composer_for(socket, id), String.trim(text))
    end
  end

  def send(socket, _params), do: {:reply, Payload.error(:invalid_params), socket}

  @doc "The composer state the conversation payload carries: ready, ambiguous, or nil (no running agent)."
  @spec state(map() | nil) :: String.t() | nil
  def state(nil), do: nil
  def state(%{writable_target?: true}), do: "ready"
  def state(_composer), do: "ambiguous"

  @spec poll(Phoenix.LiveView.Socket.t(), String.t(), integer(), non_neg_integer()) :: Phoenix.LiveView.Socket.t()
  def poll(socket, id, request_id, n) do
    if tracked?(socket, id, request_id) do
      start_async(socket, {:send_status, id, request_id, n}, fn -> OperatorSend.delivery_status(request_id, @status_timeout_ms) end)
    else
      socket
    end
  end

  @spec status(Phoenix.LiveView.Socket.t(), {:send_status, String.t(), integer(), non_neg_integer()}, term()) :: Phoenix.LiveView.Socket.t()
  def status(socket, {:send_status, id, request_id, n}, result) do
    if tracked?(socket, id, request_id), do: read(socket, id, request_id, n, result), else: socket
  end

  defp read(socket, id, request_id, _n, {:ok, {:ok, s}}) when s in [:delivered, :consumed], do: finish(socket, id, request_id, "delivered")
  defp read(socket, id, request_id, _n, {:ok, {:ok, s}}) when s in [:failed, :superseded], do: finish(socket, id, request_id, Atom.to_string(s))
  defp read(socket, id, request_id, n, {:ok, {:ok, :pending}}), do: socket |> queued(id, request_id) |> schedule(id, request_id, n + 1)
  # An unreadable status or a crashed read proves nothing; keep polling.
  defp read(socket, id, request_id, n, _result), do: schedule(socket, id, request_id, n + 1)

  defp composer_for(socket, id) do
    ref = socket.assigns.conversation_ref
    if ref && ref.id == id, do: socket.assigns.conversation_composer
  end

  defp send_to(socket, id, nil, _text), do: {:reply, failure(id, :no_running_agent), socket}
  defp send_to(socket, id, %{writable_target?: true} = composer, text), do: deliver(socket, id, composer, text)
  defp send_to(socket, id, _composer, _text), do: {:reply, failure(id, :ambiguous_identifier), socket}

  defp deliver(socket, id, composer, text) do
    case OperatorSend.send(composer, text, socket.assigns.send_pending) do
      {:ok, request_id, _message_id, pending} ->
        reply = %{
          v: 1,
          kind: "send",
          ok: true,
          id: id,
          request_id: request_id,
          entry_id: OperatorSend.transcript_id(request_id),
          text: text,
          at: System.system_time(:millisecond),
          reason: nil,
          unknown: false,
          message: nil
        }

        socket = assign(socket, send_pending: pending, send_tracking: Map.put(socket.assigns.send_tracking, id, request_id))
        {:reply, Payload.scrub(reply), schedule(socket, id, request_id, 0)}

      {:error, reason, _message_id, pending} ->
        {:reply, failure(id, reason), assign(socket, :send_pending, pending)}
    end
  end

  # Only fixed tags and copy reach the browser; an unmapped term is never shown (EC-30).
  defp failure(id, reason) do
    {tag, message} = describe(reason)
    Payload.scrub(%{v: 1, kind: "send", ok: false, id: id, request_id: nil, entry_id: nil, text: nil, at: nil, reason: tag, unknown: tag == "outcome_unknown", message: message})
  end

  defp describe({:outcome_unknown, _info} = reason), do: {"outcome_unknown", AgentLogModal.format_error(reason)}
  defp describe({:not_queued, :timeout} = reason), do: {"not_queued", AgentLogModal.format_error(reason)}
  defp describe(reason) when reason in @tags, do: {Atom.to_string(reason), AgentLogModal.format_error(reason)}
  defp describe(_reason), do: {"error", @unmapped_copy}

  defp tracked?(socket, id, request_id) do
    Map.get(socket.assigns.send_tracking, id) == request_id and (socket.assigns.conversation_ref || %{})[:id] == id
  end

  defp schedule(socket, id, request_id, n) do
    case Enum.at(delays(), n) do
      nil ->
        finish(socket, id, request_id, "unconfirmed")

      delay ->
        Process.send_after(self(), {:send_status_poll, id, request_id, n}, delay)
        socket
    end
  end

  defp queued(socket, id, request_id) do
    if MapSet.member?(socket.assigns.send_queued, request_id) do
      socket
    else
      socket |> assign(:send_queued, MapSet.put(socket.assigns.send_queued, request_id)) |> push_status(id, request_id, "queued")
    end
  end

  defp finish(socket, id, request_id, status) do
    socket
    |> assign(send_tracking: Map.delete(socket.assigns.send_tracking, id), send_queued: MapSet.delete(socket.assigns.send_queued, request_id))
    |> push_status(id, request_id, status)
  end

  defp push_status(socket, id, request_id, status), do: push_event(socket, "send-status", %{"v" => 1, "kind" => "send-status", "id" => id, "request_id" => request_id, "status" => status})

  defp delays, do: Application.get_env(:aiur, :build_send_status_delays_ms, @delays_ms)
end
