defmodule AiurWeb.Build.ConversationEventFeed do
  @moduledoc """
  Puts the ticket's event rows into the pinned conversation: into each page
  reply, and as live appends after a trigger (a transcript append, a history
  update, or a change to the open ticket's row), debounced to one read per
  second. Rows already sent are never edited or removed.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_event: 3]

  alias AiurWeb.Build.{ConversationEvents, ConversationSource, DataSource, Payload, Read}
  alias AiurWeb.EndpointConfig

  @debounce_ms 1_000
  @silent ~w(not_retained unavailable)a

  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket),
    do:
      assign(socket,
        conversation_event_ids: MapSet.new(),
        conversation_events_upper: :infinity,
        conversation_events_timer: nil,
        conversation_events_topic: nil,
        conversation_events_identity: nil
      )

  @spec clear(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def clear(socket) do
    if topic = socket.assigns[:conversation_events_topic], do: ConversationSource.call(socket.assigns.conversation_source, :events_unsubscribe, [topic])
    if timer = socket.assigns[:conversation_events_timer], do: cancel(timer)
    init(socket)
  end

  @doc "Adds the page's event rows to `view.entries`. A first view resets what was sent."
  @spec place(Phoenix.LiveView.Socket.t(), map(), map(), :first | :older) :: {map(), Phoenix.LiveView.Socket.t()}
  def place(socket, ref, view, mode) do
    socket = if mode == :first, do: assign(socket, conversation_event_ids: MapSet.new(), conversation_events_upper: :infinity), else: socket

    with false <- view[:state] in @silent,
         {:ok, built} <- build(socket, ref) do
      first? = mode == :first
      lead = if view.more?, do: [], else: built.deps ++ List.wrap(built.truncated)
      tail = if first?, do: built.tail, else: []
      {entries, upper} = ConversationEvents.page(view.entries, built.log, socket.assigns.conversation_events_upper, view.more?, %{lead: lead, tail: tail})
      entries = if first? and built.unreadable, do: [built.unreadable | entries], else: entries
      sent = entries |> Enum.filter(&event?/1) |> Enum.map(& &1.id) |> MapSet.new() |> MapSet.union(socket.assigns.conversation_event_ids)
      socket = assign(socket, conversation_event_ids: sent, conversation_events_upper: upper)
      {%{view | entries: entries}, if(first?, do: assign(socket, conversation_events_identity: built.identity), else: socket)}
    else
      _ -> {view, socket}
    end
  end

  @doc "Subscribes to the pinned ticket's history updates, once, after its conversation opened."
  @spec subscribe(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def subscribe(%{assigns: %{conversation_events_topic: nil, conversation_events_identity: identity}} = socket) when not is_nil(identity) do
    case ConversationSource.call(socket.assigns.conversation_source, :events_subscribe, [identity]) do
      {:ok, topic} when is_binary(topic) -> assign(socket, conversation_events_topic: topic)
      _ -> socket
    end
  end

  def subscribe(socket), do: socket

  @spec info(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def info(socket, {:conversation_events_refresh, id}) do
    if socket.assigns.conversation_ref.id == id, do: socket |> assign(conversation_events_timer: nil) |> refresh(), else: socket
  end

  def info(socket, {:ticket_history_updated, _snapshot}), do: schedule(socket)

  def info(socket, {:build_changes, changes}) do
    ref = socket.assigns.conversation_ref
    changes = Payload.scrub(changes)

    case changes |> Map.get("upsert") |> List.wrap() |> Enum.find(&(is_map(&1) and &1["id"] == ref.id)) do
      nil ->
        socket

      row ->
        now = changes["now"]
        resumed = ConversationEvents.resumed(ConversationEvents.agent_state(ref.row || %{}), ConversationEvents.agent_state(row), now)
        socket = assign(socket, conversation_ref: %{ref | row: Map.merge(ref.row || %{}, row)})
        socket = if resumed, do: push_new(socket, [resumed]), else: socket
        schedule(socket)
    end
  end

  def info(socket, _message), do: socket

  @spec schedule(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def schedule(%{assigns: %{conversation_ref: %{id: id}, conversation_events_timer: nil}} = socket) do
    timer = (EndpointConfig.get(:build_events_timer) || (&Process.send_after/3)).(self(), {:conversation_events_refresh, id}, @debounce_ms)
    assign(socket, conversation_events_timer: timer)
  end

  def schedule(socket), do: socket

  # Only rows inside the pages already sent are appended; older log rows wait for their page.
  defp refresh(socket) do
    case build(socket, socket.assigns.conversation_ref) do
      {:ok, built} ->
        upper = socket.assigns.conversation_events_upper
        deps = if upper == :none, do: built.deps, else: []
        push_new(socket, Enum.filter(built.log, &ConversationEvents.shown?(&1, upper)) ++ deps ++ built.tail)

      _ ->
        socket
    end
  end

  defp push_new(socket, events) do
    sent = socket.assigns.conversation_event_ids

    case Enum.reject(events, &MapSet.member?(sent, &1.id)) do
      [] ->
        socket

      fresh ->
        message = Payload.scrub(%{v: 1, kind: "conversation-append", id: socket.assigns.conversation_ref.id, entries: fresh, gap: false})

        if Payload.validate(message) == :ok,
          do: socket |> assign(conversation_event_ids: MapSet.union(sent, MapSet.new(fresh, & &1.id))) |> push_event("build-conversation", message),
          else: socket
    end
  end

  defp build(socket, ref) do
    with {:ok, facts} <- ConversationSource.call(socket.assigns.conversation_source, :events, [ref]) do
      row = ref.row || %{}
      deps = Map.new(row["deps"] || [], &{&1, dep_row(socket, &1)})
      current = ConversationEvents.current_facts(row, Map.merge(facts, %{deps: deps, by_you_at: nil}))
      {log, unreadable, truncated} = log(facts, ref.id)
      {:ok, %{log: log, deps: current.deps, tail: current.tail, unreadable: unreadable, truncated: truncated, identity: facts[:identity]}}
    end
  end

  defp log(facts, id) do
    case facts[:log] do
      {:ok, rows} ->
        truncated = if length(rows) >= ConversationEvents.log_limit(), do: ConversationEvents.sys("ev:sys:truncated", "Earlier ticket events not shown", nil)
        {ConversationEvents.from_log(rows, id, ConversationEvents.progress_index(facts[:history])), nil, truncated}

      {:error, :missing_source} ->
        {[], nil, nil}

      _ ->
        {[], ConversationEvents.sys("ev:sys:unreadable", "Ticket events could not be read", facts[:read_at]), nil}
    end
  end

  defp dep_row(socket, id) do
    case Read.safe_read(fn -> DataSource.call(socket.assigns.build_source, :ticket, [id, Read.source_opts(socket)]) end) do
      {:ok, row} when is_map(row) -> Payload.scrub(row)
      _ -> nil
    end
  end

  defp cancel(timer) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel(_timer), do: :ok

  defp event?(%{id: "ev:" <> _}), do: true
  defp event?(_entry), do: false
end
