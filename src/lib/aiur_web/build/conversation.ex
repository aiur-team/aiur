defmodule AiurWeb.Build.Conversation do
  @moduledoc "Owns the build modal's pinned read, subscriptions and bounded tail poll."
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_event: 3]
  require Logger
  alias AiurWeb.Build.{Composer, ConversationEventFeed, ConversationPayload, ConversationSource, DataSource, Payload, Read, URLState}
  alias AiurWeb.OperatorControlCenter.AgentLogModal

  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket) do
    assign(socket,
      conversation_source: ConversationSource.source(),
      conversation_ref: nil,
      conversation_handle: nil,
      conversation_last: nil,
      conversation_timer: nil,
      conversation_composer: nil,
      conversation_view: nil,
      conversation_drain: false,
      conversation_stat: nil
    )
    |> ConversationEventFeed.init()
  end

  @spec page(Phoenix.LiveView.Socket.t(), map()) :: {:reply, map(), Phoenix.LiveView.Socket.t()}
  def page(socket, %{"id" => id} = params) when is_binary(id) do
    before = params["before"]

    cond do
      URLState.parse(%{"ticket" => id}).ticket != id -> reply_error(socket, :invalid_params)
      before == nil -> first(socket, id)
      not is_binary(before) -> reply_error(socket, :invalid_params)
      socket.assigns.conversation_ref == nil or socket.assigns.conversation_ref.id != id -> reply_error(socket, :invalid_params)
      true -> older(socket, before)
    end
  end

  def page(socket, _params), do: reply_error(socket, :invalid_params)

  @spec close(Phoenix.LiveView.Socket.t(), map()) :: {:reply, map(), Phoenix.LiveView.Socket.t()}
  def close(socket, %{"id" => id}) when is_binary(id) do
    socket = if socket.assigns.conversation_ref && socket.assigns.conversation_ref.id == id, do: clear(socket), else: socket
    {:reply, %{"v" => 1, "kind" => "ok"}, socket}
  end

  def close(socket, _params), do: reply_error(socket, :invalid_params)

  @spec clear(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def clear(socket) do
    if ref = socket.assigns.conversation_ref do
      case call(socket, :unsubscribe, [ref]) do
        :ok -> :ok
        _ -> Logger.warning("build conversation unsubscribe unavailable ticket=#{ref.id}")
      end
    end

    if timer = socket.assigns.conversation_timer, do: Process.cancel_timer(timer)

    assign(socket,
      conversation_ref: nil,
      conversation_handle: nil,
      conversation_last: nil,
      conversation_timer: nil,
      conversation_composer: nil,
      conversation_view: nil,
      conversation_drain: false,
      conversation_stat: nil
    )
    |> ConversationEventFeed.clear()
  end

  @spec info(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def info(%{assigns: %{conversation_ref: nil}} = socket, _message), do: socket

  def info(socket, {:build_conversation_poll, token}) do
    if socket.assigns.conversation_poll_token == token do
      signature = signature(socket.assigns.conversation_ref)
      socket = assign(socket, conversation_timer: nil)
      socket = if socket.assigns.conversation_drain or signature != socket.assigns.conversation_stat, do: update(socket, false), else: socket
      schedule(socket)
    else
      socket
    end
  end

  def info(socket, :fleet_changed), do: refresh(socket)

  def info(socket, {:live_conversation_changed, snapshot}) do
    if snapshot[:generation_handle] == socket.assigns.conversation_handle, do: update(socket, true), else: socket
  end

  def info(socket, {:live_conversation_restarted, _epoch, _now}), do: update(socket, true)
  def info(socket, {tag, _} = message) when tag in [:conversation_events_refresh, :ticket_history_updated, :build_changes], do: ConversationEventFeed.info(socket, message)
  def info(socket, _message), do: socket

  defp first(socket, id) do
    with {:ok, row} <- Read.safe_read(fn -> DataSource.call(socket.assigns.build_source, :ticket, [id, Read.source_opts(socket)]) end),
         true <- eligible?(row),
         :ok <- Payload.validate(Payload.ticket(row, socket.assigns.build_epoch, socket.assigns.build_generation)) do
      socket = clear(socket)
      ref = %{id: id, identity: row["identity"], running: nil, closed?: row["sec"] == "hist", row: row}

      case prepare(socket, ref) do
        {:ok, ref} -> open(socket, ref)
        {:error, _reason} -> reply_error(socket, :unavailable)
      end
    else
      {:error, :not_found} -> reply_error(socket, :invalid_params)
      false -> reply_error(socket, :invalid_params)
      _ -> reply_error(socket, :unavailable)
    end
  end

  defp eligible?(row), do: is_map(row["agent"]) and row["start"] != nil

  defp open(socket, ref) do
    with {:ok, view} <- call(socket, :tail, [ref, nil]),
         {view, socket} = ConversationEventFeed.place(socket, ref, view, :first),
         message = composed(ConversationPayload.view(ref.id, view), ref),
         :ok <- Payload.validate(message),
         :ok <- call(socket, :subscribe, [ref]) do
      socket = socket |> pin(ref, view) |> ConversationEventFeed.subscribe() |> schedule()
      {:reply, message, socket}
    else
      _ -> reply_error(socket, :unavailable)
    end
  end

  defp older(socket, before) do
    ref = socket.assigns.conversation_ref

    case call(socket, :page, [ref, before]) do
      {:ok, view} ->
        {view, socket} = ConversationEventFeed.place(socket, ref, view, :older)
        message = Payload.scrub(%{v: 1, kind: "conversation-earlier", id: ref.id, entries: view.entries, before: view[:before], more: view.more?})
        validated_reply(socket, message)

      {:error, :invalid_cursor} ->
        reply_error(socket, :invalid_params)

      {:error, :reset} ->
        reset(socket, ref)

      _ ->
        reply_error(socket, :unavailable)
    end
  end

  defp reset(socket, ref) do
    case call(socket, :tail, [ref, nil]) do
      {:ok, view} ->
        {view, socket} = ConversationEventFeed.place(socket, ref, view, :first)
        validated_reply(pin(socket, ref, view), composed(ConversationPayload.view(ref.id, view, true), ref))

      _ ->
        reply_error(socket, :unavailable)
    end
  end

  defp pin(socket, ref, view) do
    composer = composer(ref)

    assign(socket,
      conversation_ref: ref,
      conversation_handle: ref[:handle],
      conversation_last: view[:last],
      conversation_composer: composer,
      conversation_view: view,
      conversation_stat: signature(ref)
    )
  end

  defp composer(%{running: entry, fleet: %{fleet: %{running: running} = fleet}}) when is_map(entry) do
    payload = %{fleet: %{fleet | running: Enum.map(running, &composer_entry/1)}}
    AgentLogModal.composer(composer_entry(entry), payload)
  end

  defp composer(_ref), do: nil
  defp composed(message, ref), do: Map.put(message, "composer", Composer.state(composer(ref)))
  defp composer_entry(entry), do: Map.put_new(entry, :issue_identifier, entry[:identifier])

  defp prepare(socket, ref) do
    source = socket.assigns.conversation_source
    module = if is_tuple(source), do: elem(source, 0), else: source
    if Code.ensure_loaded?(module) and function_exported?(module, :prepare, 2), do: call(socket, :prepare, [ref]), else: {:ok, ref}
  end

  defp update(socket, refresh?) do
    old = socket.assigns.conversation_ref

    with {:ok, ref} <- if(refresh?, do: prepare(socket, old), else: {:ok, old}),
         :ok <- resubscribe(socket, old, ref) do
      socket |> assign(conversation_ref: ref, conversation_handle: ref[:handle]) |> read_update(ref) |> schedule()
    else
      _ -> push_unavailable(socket)
    end
  end

  defp refresh(socket) do
    old = socket.assigns.conversation_ref

    case prepare(socket, old) do
      {:ok, ref} ->
        if changed_ref?(old, ref), do: update(socket, true), else: socket

      _ ->
        push_unavailable(socket)
    end
  end

  defp changed_ref?(old, ref) do
    fields = [:handle, :running_unknown?, :reason, :remote?, :workspace]
    Map.take(old, fields) != Map.take(ref, fields) or old[:running] == nil != (ref[:running] == nil)
  end

  defp resubscribe(socket, old, ref) do
    if old[:handle] == ref[:handle] do
      :ok
    else
      call(socket, :unsubscribe, [old])
      call(socket, :subscribe, [ref])
    end
  end

  defp read_update(socket, ref) do
    case call(socket, :tail, [ref, socket.assigns.conversation_last]) do
      {:ok, view} ->
        old = socket.assigns.conversation_view
        gap = (view[:evicted] || 0) > (old[:evicted] || 0)
        socket = if view.entries == [], do: socket, else: socket |> push(%{v: 1, kind: "conversation-append", id: ref.id, entries: view.entries, gap: gap}) |> ConversationEventFeed.schedule()
        socket = push(socket, %{v: 1, kind: "conversation-state", id: ref.id, state: view.state, live: view.live?, observed_at: ConversationPayload.millis(view[:observed_at])})
        socket |> pin(ref, view) |> assign(conversation_drain: view.more?)

      {:error, :reset} ->
        case call(socket, :tail, [ref, nil]) do
          {:ok, view} ->
            {view, socket} = ConversationEventFeed.place(socket, ref, view, :first)
            push(pin(socket, ref, view), composed(ConversationPayload.view(ref.id, view, true), ref))

          _ ->
            push_unavailable(socket)
        end

      _ ->
        push_unavailable(socket)
    end
  end

  defp push_unavailable(socket) do
    push(assign(socket, conversation_drain: true), %{v: 1, kind: "conversation-state", id: socket.assigns.conversation_ref.id, state: "unavailable", live: false, observed_at: nil})
  end

  defp schedule(socket) do
    if socket.assigns.conversation_timer == nil and local?(socket.assigns.conversation_ref) do
      token = make_ref()
      timer = Process.send_after(self(), {:build_conversation_poll, token}, 1_000)
      assign(socket, conversation_timer: timer, conversation_poll_token: token)
    else
      socket
    end
  end

  defp local?(ref), do: is_binary(ref[:path]) and not is_binary((ref[:running] || %{})[:worker_host])

  defp signature(%{path: path}) when is_binary(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {stat.size, stat.inode, stat.mtime, stat.ctime}
      {:error, reason} -> {:error, reason}
    end
  end

  defp signature(_ref), do: nil

  defp call(socket, function, args) do
    ConversationSource.call(socket.assigns.conversation_source, function, args)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp validated_reply(socket, message) do
    if Payload.validate(message) == :ok, do: {:reply, message, socket}, else: reply_error(socket, :unavailable)
  end

  defp push(socket, message) do
    message = Payload.scrub(message)

    if Payload.validate(message) == :ok do
      push_event(socket, "build-conversation", message)
    else
      Logger.warning("build conversation rejected invalid source payload ticket=#{socket.assigns.conversation_ref.id}")
      socket
    end
  end

  defp reply_error(socket, reason), do: {:reply, Payload.error(reason), socket}
end
