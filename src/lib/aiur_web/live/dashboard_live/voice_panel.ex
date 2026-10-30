defmodule AiurWeb.DashboardLive.VoicePanel do
  @moduledoc "Retained Executor prototype and worker conversation entry points."

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.{ConversationDrawer, ConversationLink, ExecutorVoice, UnitsPresenter}

  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket) do
    assign(socket,
      agent_log_modal: nil,
      drafts: %{},
      pending_message_ids: %{},
      chat_errors: %{},
      conversation_drawer: nil,
      conversation_handle: nil,
      conversation_identity: nil,
      conversation_row: nil,
      conversation_origin_id: nil,
      conversation_lifecycle: :active,
      conversation_snapshot: nil,
      conversation_usage_snapshot: nil,
      conversation_usage_error: nil,
      conversation_log: nil,
      listener_identifier: nil,
      listener_timer: nil,
      listener_view: :unavailable,
      listener_feedback: %{},
      listener_receipts: [],
      listener_receipts_busy: false
    )
  end

  @spec panel(map()) :: Phoenix.LiveView.Rendered.t()
  def panel(assigns) do
    catalog = Map.get(assigns.payload, :units) || %{}

    assigns =
      assigns
      |> assign(:voice_workers, workers(catalog))
      |> assign(:voice_catalog_status, Map.get(catalog, :status, :unavailable))
      |> assign(:voice_catalog_message, Map.get(catalog, :message))

    ~H"""
    <section id="executor-voice-host" class="section-card" phx-hook="ExecutorVoice" aria-labelledby="executor-voice-heading">
      <h2 id="executor-voice-heading">Talk to Executor</h2>
      <ExecutorVoice.executor_voice id="executor-voice-prototype" writable={@writable} />
    </section>
    <section id="voice-workers" class="section-card" aria-labelledby="voice-workers-heading">
      <h2 id="voice-workers-heading">Worker conversations</h2>
      <p>Open a worker conversation for messages, Dictate and Converse.</p>
      <p :if={is_nil(@voice_workers)} role="status" data-worker-status={@voice_catalog_status}>
        Worker conversations are unavailable. <span :if={@voice_catalog_message}>{@voice_catalog_message}</span>
      </p>
      <p :if={@voice_catalog_status == :stale} role="status">Worker list is stale. {@voice_catalog_message}</p>
      <p :if={@voice_workers == [] and @voice_catalog_status in [:ready, :empty]}>No workers are listed.</p>
      <ul :if={is_list(@voice_workers)}>
        <li :for={worker <- @voice_workers}>
          <span>{worker.label}</span>
          <button id={worker.id} class="aiur-button aiur-button--dashboard" type="button"
            phx-click="read-conversation" phx-value-unit={worker.token}
            disabled={!worker.available} aria-label={"Open conversation for #{worker.label}"}>
            Open conversation
          </button>
          <span :if={!worker.available}>Conversation unavailable.</span>
        </li>
      </ul>
    </section>
    <ConversationDrawer.conversation_drawer
      id="voice-conversation-drawer"
      view={@conversation_drawer}
      full_conversation_href={ConversationLink.href(Map.get(@conversation_row || %{}, :identity))}
      composer={@agent_log_modal}
      writable={@writable}
      drafts={@drafts}
      errors={@chat_errors}
      usage_snapshot={@conversation_usage_snapshot}
      usage_error={@conversation_usage_error}
      context_occupancy={Map.get(@conversation_row || %{}, :context_usage)}
      voice_capabilities={@voice_capabilities}
      voice_conversation_error={@voice_conversation_error}
      listener={@listener_view}
      listener_feedback={@listener_feedback}
      receipts={@listener_receipts}
      now={@now}
      close_event="close-conversation"
      fallback_focus_id="voice-workers"
      origin_id={@conversation_origin_id}
      show_executor_voice={false}
    />
    """
  end

  defp has_conversation?(%{live_conversation: %{generation_handle: handle}}), do: is_binary(handle)
  defp has_conversation?(_row), do: false

  defp workers(catalog) do
    case catalog do
      %{status: status, snapshot: %{rows: rows}} when status in [:ready, :empty, :stale] and is_list(rows) ->
        rows
        |> Enum.with_index()
        |> Enum.map(fn {row, index} ->
          token = UnitsPresenter.row_token(row)
          identity = Map.get(row, :identity) || %{}

          %{
            token: token,
            id: "voice-conversation-#{token || index}",
            label: Map.get(identity, :identifier) || "Unknown ticket",
            available: is_binary(token) and has_conversation?(row)
          }
        end)

      _unavailable ->
        nil
    end
  end
end
