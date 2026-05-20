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

  @impl true
  def handle_info({:transcript_event, %{role: :user}}, state), do: {:noreply, state}

  def handle_info({:transcript_event, event}, state) do
    publish_event(state, event)
    {:noreply, state}
  end

  def handle_info({:alert, %{message: message}}, state) do
    _ = ApiClient.post_message(state.base_url, state.session_id, Protocol.alert_message_part(message))
    _ = ApiClient.show_toast(state.base_url, "Aiur", message, :warning)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp replay_history(state) do
    state.identifier
    |> IssueLog.history(500)
    |> Enum.each(&publish_event(state, &1))
  end

  defp publish_event(state, %{role: :assistant, body: body}),
    do: ApiClient.post_message(state.base_url, state.session_id, Protocol.assistant_text_message(body))

  defp publish_event(state, %{role: :command, body: body}),
    do: ApiClient.post_message(state.base_url, state.session_id, Protocol.assistant_command_message(body, ""))

  defp publish_event(state, %{role: :system, body: body}),
    do: ApiClient.post_message(state.base_url, state.session_id, Protocol.system_message_part(body))

  defp publish_event(state, %{role: :alert, body: body}),
    do: ApiClient.post_message(state.base_url, state.session_id, Protocol.alert_message_part(body))

  defp publish_event(_state, _event), do: :ok
end
