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
    {workers, hidden} = worker_state(assigns, catalog)
    page = min(Map.get(assigns, :voice_page, 0), max(page_count(workers) - 1, 0))

    assigns =
      assigns
      |> assign(:voice_workers, workers)
      |> assign(:voice_hidden_workers, hidden)
      |> assign(:voice_page, page)
      |> assign(:voice_page_rows, page_rows(workers, page))
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
      <p :if={@voice_hidden_workers > 0} class="voice-hidden-count" data-hidden-workers={@voice_hidden_workers}>
        {hidden_count_label(@voice_hidden_workers)}
      </p>
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

  # Resolving a worker costs a subject-index lookup and a snapshot read per row,
  # so the panel resolves availability once per catalog change and renders the
  # assigned result. Rendering a 745-row catalog must not re-resolve history.
  @doc false
  @spec assign_workers(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def assign_workers(socket, opts \\ [])

  def assign_workers(%{assigns: %{live_action: :voice}} = socket, opts) do
    catalog = Map.get(socket.assigns[:payload] || %{}, :units) || %{}

    if Map.get(socket.assigns, :voice_worker_catalog) == catalog do
      socket
    else
      %{workers: workers, hidden: hidden} = resolve(catalog, opts)
      assign(socket, voice_worker_catalog: catalog, voice_workers: workers, voice_hidden_workers: hidden)
    end
  end

  def assign_workers(socket, _opts), do: socket

  defp worker_state(%{voice_workers: workers} = assigns, _catalog),
    do: {workers, Map.get(assigns, :voice_hidden_workers) || 0}

  defp worker_state(_assigns, catalog) do
    %{workers: workers, hidden: hidden} = resolve(catalog)
    {workers, hidden}
  end

  defp hidden_count_label(1), do: "1 ticket has no conversation."
  defp hidden_count_label(count), do: "#{count} tickets have no conversation."

  @doc false
  @spec workers(map(), keyword()) :: [map()] | nil
  def workers(catalog, opts \\ []), do: resolve(catalog, opts).workers

  @doc false
  @spec resolve(map(), keyword()) :: %{workers: [map()] | nil, hidden: non_neg_integer()}
  def resolve(catalog, opts \\ []) do
    history_resolver = Keyword.get(opts, :history_resolver, &History.resolve_worker/3)

    case catalog do
      %{status: status, snapshot: %{rows: rows}} when status in [:ready, :empty, :stale] and is_list(rows) ->
        {available, hidden} = Enum.split_with(rows, &conversation_available?(&1, history_resolver))
        %{workers: Enum.map(available, &worker_entry/1), hidden: length(hidden)}

      _unavailable ->
        %{workers: nil, hidden: 0}
    end
  end

  defp worker_entry(row) do
    token = UnitsPresenter.row_token(row)
    identity = Map.get(row, :identity) || %{}

    %{
      id: "voice-conversation-#{token}",
      label: Map.get(identity, :identifier) || "Unknown ticket",
      token: token
    }
  end

  @page_size 25
  @spec conversation_available?(map(), (String.t(), String.t(), String.t() -> term())) :: boolean()
  defp conversation_available?(row, history_resolver) do
    has_conversation?(row) or
      case Map.get(row, :identity) do
        %TrackerIdentity{} = identity ->
          case Conversation.Ref.worker(identity) do
            {:ok, _ref} -> match?({:ok, _}, history_resolver.(identity.owner, identity.repository, identity.identifier))
            _ -> false
          end

        _ ->
          false
      end
  end

  @spec page_rows([map()] | nil, non_neg_integer()) :: [map()]
  def page_rows(workers, page) when is_list(workers), do: Enum.slice(workers, page * @page_size, @page_size)
  def page_rows(_, _), do: []
  @spec page_count([map()] | nil) :: non_neg_integer()
  def page_count(workers) when is_list(workers), do: max(1, div(length(workers) + @page_size - 1, @page_size))
  def page_count(_), do: 0
end
