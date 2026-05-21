defmodule Aiur.Opencode.TranscriptRelay do
  @moduledoc false

  use GenServer

  alias Aiur.{AgentPubSub, IssueLog}
  alias Aiur.Opencode.{ApiClient, Protocol}

  defstruct [:identifier, :base_url, :session_id]

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      identifier: Map.fetch!(opts, :identifier),
      base_url: Map.fetch!(opts, :base_url),
      session_id: Map.fetch!(opts, :session_id)
    }

    :ok = AgentPubSub.subscribe_agent(state.identifier)
    replay_history(state)
    {:ok, state}
  end

  # Live transcript events are streamed back as `assistant` deltas on the chat-completion SSE
  # connection (see `Aiur.Opencode.ChatCompletions.stream_loop/4`). Re-posting them here as
  # POST /session/<id>/message would echo every agent reply as a *user* message (the only role
  # the message-input endpoint supports) and trigger a recursive /v1/chat/completions call.
  @impl true
  def handle_info({:transcript_event, _event}, state), do: {:noreply, state}

  def handle_info({:alert, %{message: message}}, state) do
    _ = ApiClient.post_message(state.base_url, state.session_id, alert_part(message))
    _ = ApiClient.show_toast(state.base_url, "Aiur", message, :warning)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp replay_history(state) do
    events =
      case IssueLog.history(state.identifier, 500) do
        [] -> IssueLog.disk_history(state.identifier, 500)
        list -> list
      end

    body =
      events
      |> Enum.map(&format_history/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    if body != "" do
      payload =
        Protocol.user_message_part("**Prior session history (Aiur):**\n\n" <> body)
        |> Map.put("noReply", true)

      _ = ApiClient.post_message(state.base_url, state.session_id, payload)
    end
  end

  defp format_history(%{role: :assistant, body: body}), do: "🤖 **Agent:** #{body}"
  defp format_history(%{role: :user, body: body}), do: "💬 **You:** #{body}"
  defp format_history(%{role: :command, body: body}), do: "```\n$ #{body}\n```"
  defp format_history(%{role: :system, body: body}), do: "_(system: #{body})_"
  defp format_history(%{role: :alert, body: body}), do: "⚠️ **Alert:** #{body}"
  defp format_history(_event), do: nil

  defp alert_part(body) do
    Protocol.user_message_part("⚠️ **Aiur alert:** #{body}")
    |> Map.put("noReply", true)
  end
end
