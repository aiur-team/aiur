defmodule AiurWeb.DashboardLive.VoicePanel do
  @moduledoc "Retained Executor prototype and worker conversation entry points."

  use Phoenix.Component

  alias Aiur.Conversation
  alias Aiur.Conversation.History
  alias Aiur.TrackerIdentity
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
      listener_receipts_busy: false,
      voice_page: 0
    )
  end

  @spec panel(map()) :: Phoenix.LiveView.Rendered.t()
  def panel(assigns) do
    catalog = Map.get(assigns.payload, :units) || %{}
    workers = workers(catalog)

    assigns =
      assigns
      |> assign(:voice_workers, workers)
      |> assign(:voice_page_rows, page_rows(workers, Map.get(assigns, :voice_page, 0)))
      |> assign(:voice_page_count, page_count(workers))
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
      <p :if={is_list(@voice_workers) and @voice_workers != []}>Showing {@voice_page + 1} of {@voice_page_count} pages.</p>
      <ul :if={is_list(@voice_workers)}>
        <li :for={worker <- @voice_page_rows}>
          <span>{worker.label}</span>
          <button id={worker.id} class="aiur-button aiur-button--dashboard" type="button"
            phx-click="read-conversation" phx-value-unit={worker.token}
            aria-label={"Open conversation for #{worker.label}"}>
            Open conversation
          </button>
        </li>
      </ul>
      <nav :if={@voice_page_count > 1} aria-label="Worker conversation pages">
        <button type="button" phx-click="voice-page" phx-value-page={max(@voice_page - 1, 0)} disabled={@voice_page == 0}>Previous</button>
        <button type="button" phx-click="voice-page" phx-value-page={min(@voice_page + 1, @voice_page_count - 1)} disabled={@voice_page + 1 >= @voice_page_count}>Next</button>
      </nav>
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
        |> Enum.filter(&conversation_available?/1)
        |> Enum.map(fn row ->
          token = UnitsPresenter.row_token(row)
          identity = Map.get(row, :identity) || %{}

          %{
            id: "voice-conversation-#{token}",
            label: Map.get(identity, :identifier) || "Unknown ticket",
            token: token
          }
        end)

      _unavailable ->
        nil
    end
  end

  @page_size 25
  defp conversation_available?(row) do
    has_conversation?(row) or
      case Map.get(row, :identity) do
        %TrackerIdentity{} = identity ->
          case Conversation.Ref.worker(identity) do
            {:ok, ref} -> match?({:ok, _}, History.snapshot(ref))
            _ -> false
          end

        _ ->
          false
      end
  rescue
    _error -> false
  end

  @spec page_rows([map()] | nil, non_neg_integer()) :: [map()]
  def page_rows(workers, page) when is_list(workers), do: Enum.slice(workers, page * @page_size, @page_size)
  def page_rows(_, _), do: []
  @spec page_count([map()] | nil) :: non_neg_integer()
  def page_count(workers) when is_list(workers), do: max(1, div(length(workers) + @page_size - 1, @page_size))
  def page_count(_), do: 0
end
