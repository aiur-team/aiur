defmodule AiurWeb.BuildOrder.ContextRuntime do
  @moduledoc "Root- and generation-scoped cached Ticket Context orchestration."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, start_async: 3]

  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.{Runtime, TicketContextAdapter, TicketContextPresenter, TicketContextSelection}
  alias Phoenix.LiveView.Socket

  @spec initialize(Socket.t(), term()) :: Socket.t()
  def initialize(socket, request_epoch) do
    socket
    |> assign(:context_selection, TicketContextSelection.new(request_epoch))
    |> assign(:context_base, nil)
    |> assign(:context_view, TicketContextAdapter.present(nil, nil, nil))
    |> assign(:context_loading_tokens, MapSet.new())
    |> assign(:context_reload_queued?, false)
  end

  @spec reconcile(Socket.t()) :: Socket.t()
  def reconcile(socket) do
    old_selection = socket.assigns.context_selection

    selection =
      case socket.assigns.model do
        %AiurWeb.BuildOrderViewModel{} = model -> TicketContextSelection.reconcile(old_selection, model)
        _model -> TicketContextSelection.close(old_selection)
      end

    socket
    |> assign(:context_selection, selection)
    |> reconcile_scope(old_selection)
    |> assign_view()
  end

  @spec open(Socket.t(), term()) :: Socket.t()
  def open(socket, navigation_value) do
    selection = TicketContextSelection.open(socket.assigns.context_selection, socket.assigns.model, navigation_value)
    put_selection(socket, selection)
  end

  @spec replace(Socket.t(), term()) :: Socket.t()
  def replace(socket, navigation_value) do
    selection = TicketContextSelection.replace(socket.assigns.context_selection, socket.assigns.model, navigation_value)
    put_selection(socket, selection)
  end

  @spec back(Socket.t()) :: Socket.t()
  def back(socket) do
    selection = TicketContextSelection.back(socket.assigns.context_selection, socket.assigns.model)
    put_selection(socket, selection)
  end

  @spec close(Socket.t()) :: Socket.t()
  def close(socket), do: put_selection(socket, TicketContextSelection.close(socket.assigns.context_selection))

  @spec refresh_for(Socket.t(), TrackerIdentity.t()) :: Socket.t()
  def refresh_for(socket, identity) do
    if same_identity?(open_identity(socket.assigns.context_selection), identity),
      do: refresh(socket),
      else: socket
  end

  @spec refresh(Socket.t()) :: Socket.t()
  def refresh(%{assigns: %{context_selection: %TicketContextSelection{status: :open}}} = socket) do
    put_selection(socket, TicketContextSelection.refresh(socket.assigns.context_selection))
  end

  def refresh(socket), do: socket

  @spec complete(Socket.t(), term(), TrackerIdentity.t(), term()) :: Socket.t()
  def complete(socket, token, identity, result) do
    socket = drop_loading_token(socket, token)

    socket =
      if TicketContextSelection.current_completion?(socket.assigns.context_selection, token, identity) do
        socket
        |> assign(:context_base, context_base(result, identity, socket.assigns.model))
        |> assign_view()
      else
        socket
      end

    finish_reload(socket, token)
  end

  @spec failed(Socket.t(), term()) :: Socket.t()
  def failed(socket, token), do: socket |> drop_loading_token(token) |> finish_reload(token)

  @spec terminate(Socket.t()) :: :ok
  def terminate(socket) do
    case socket.assigns.context_selection do
      %TicketContextSelection{status: :open, selected: %TrackerIdentity{} = identity} ->
        _ = Runtime.safe_source_call(socket.assigns.source, :unsubscribe_context, [identity], :ok)

      _selection ->
        :ok
    end

    :ok
  end

  defp put_selection(socket, %TicketContextSelection{} = selection) do
    old_selection = socket.assigns.context_selection

    socket
    |> assign(:context_selection, selection)
    |> reconcile_scope(old_selection)
    |> assign_view()
  end

  defp reconcile_scope(socket, old_selection) do
    old_identity = open_identity(old_selection)
    new_identity = open_identity(socket.assigns.context_selection)
    identity_changed? = not same_identity?(old_identity, new_identity)

    if identity_changed? and is_struct(old_identity, TrackerIdentity) do
      _ = Runtime.safe_source_call(socket.assigns.source, :unsubscribe_context, [old_identity], :ok)
    end

    if identity_changed? and is_struct(new_identity, TrackerIdentity) do
      _ = Runtime.safe_source_call(socket.assigns.source, :subscribe_context, [new_identity], :ok)
    end

    socket =
      if identity_changed?,
        do: assign(socket, :context_base, fallback_context(new_identity, socket.assigns.model)),
        else: socket

    if request_changed?(old_selection, socket.assigns.context_selection),
      do: schedule_load(socket),
      else: socket
  end

  defp schedule_load(%{assigns: %{context_selection: %TicketContextSelection{status: :open} = selection}} = socket) do
    token = selection.request_token
    identity = selection.selected

    cond do
      not connected?(socket) ->
        socket

      not is_binary(token) or not is_struct(identity, TrackerIdentity) ->
        socket

      MapSet.size(socket.assigns.context_loading_tokens) > 0 ->
        assign(socket, :context_reload_queued?, true)

      true ->
        source = socket.assigns.source

        socket
        |> assign(:context_loading_tokens, MapSet.put(socket.assigns.context_loading_tokens, token))
        |> start_async({:build_order_context, token}, fn ->
          {identity, Runtime.safe_source_call(source, :load_context, [identity], %{})}
        end)
    end
  end

  defp schedule_load(socket), do: socket

  defp drop_loading_token(socket, token),
    do: assign(socket, :context_loading_tokens, MapSet.delete(socket.assigns.context_loading_tokens, token))

  defp finish_reload(socket, token) do
    queued? = socket.assigns.context_reload_queued?
    socket = assign(socket, :context_reload_queued?, false)

    if queued? and not current_token?(socket.assigns.context_selection, token),
      do: schedule_load(socket),
      else: socket
  end

  defp current_token?(%TicketContextSelection{status: :open, request_token: token}, token), do: true
  defp current_token?(_selection, _token), do: false

  defp assign_view(%{assigns: %{context_selection: %TicketContextSelection{status: :open} = selection}} = socket) do
    base = socket.assigns.context_base || fallback_context(selection.selected, socket.assigns.model)

    view =
      TicketContextAdapter.present(
        socket.assigns.model,
        selection.selected,
        base,
        context_capabilities(socket.assigns.model, selection.selected)
      )

    assign(socket, :context_view, view)
  end

  defp assign_view(socket),
    do: socket |> assign(:context_base, nil) |> assign(:context_view, TicketContextAdapter.present(nil, nil, nil))

  defp context_base(%{detail: {:ok, detail}, history: {:ok, history}}, identity, model) do
    case TicketContextPresenter.present(detail, history) do
      %{identity: %TrackerIdentity{}} = base -> base
      _base -> fallback_context(identity, model)
    end
  end

  defp context_base(_result, identity, model), do: fallback_context(identity, model)

  defp fallback_context(%TrackerIdentity{} = identity, model) do
    base = TicketContextPresenter.normalize_view(nil)
    node = context_node(model, identity)

    %{
      base
      | identity: identity,
        repository: "#{identity.owner}/#{identity.repository}",
        identifier: identity.identifier,
        title: if(node, do: node.title, else: "Ticket ##{identity.identifier}"),
        description: if(node, do: Map.get(node, :draft_body), else: nil)
    }
  end

  defp fallback_context(_identity, _model), do: TicketContextPresenter.normalize_view(nil)

  defp context_capabilities(model, %TrackerIdentity{} = identity) do
    case context_node(model, identity) do
      %{card: %{planned?: true}} ->
        %{}

      # An external planning document may be available for a non-draft member.
      %{document_url: doc} when is_binary(doc) ->
        %{document: %{available?: true, destination: doc, identity: identity, label: "Planning doc"}}

      %{url: url} when is_binary(url) ->
        %{issue: %{available?: true, destination: url, identity: identity, label: "GitHub issue"}}

      _node ->
        %{}
    end
  end

  defp context_capabilities(_model, _identity), do: %{}

  defp context_node(%AiurWeb.BuildOrderViewModel{nodes: nodes}, identity) do
    key = TrackerIdentity.github_key(identity)
    Enum.find(nodes, &(TrackerIdentity.github_key(&1.identity) == key))
  end

  defp context_node(_model, _identity), do: nil

  defp open_identity(%TicketContextSelection{status: :open, selected: identity}), do: identity
  defp open_identity(_selection), do: nil

  defp request_changed?(%TicketContextSelection{request_token: token}, %TicketContextSelection{request_token: token}),
    do: false

  defp request_changed?(_old, %TicketContextSelection{status: :open}), do: true
  defp request_changed?(_old, _new), do: false

  defp same_identity?(nil, nil), do: true

  defp same_identity?(%TrackerIdentity{} = left, %TrackerIdentity{} = right),
    do:
      not is_nil(TrackerIdentity.github_key(left)) and
        TrackerIdentity.github_key(left) == TrackerIdentity.github_key(right)

  defp same_identity?(_left, _right), do: false
end
