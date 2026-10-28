defmodule AiurWeb.Conversation.Commands do
  @moduledoc false
  import Phoenix.Component, only: [assign: 2, assign: 3]
  alias Aiur.Conversation.{History, Ref}
  alias AiurWeb.Conversation.Paging
  alias AiurWeb.EndpointConfig
  alias AiurWeb.OperatorControlCenter.{DecisionEvents, DecisionProvider}

  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket), do: assign(socket, decision_page: %{decisions: []}, decision_actions: %{}, selected_decision_id: nil, selected_decision: nil, command_slots: %{}, commands_error: nil)

  @spec subscribe(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def subscribe(socket) do
    :ok = Aiur.DecisionPubSub.subscribe()
    reload(socket)
  end

  @spec reload(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reload(socket) do
    with {:ok, params} <- subject(socket.assigns.id),
         {:ok, page} <- DecisionProvider.list(Map.merge(params, %{"lifecycle" => "open", "limit" => 100}), options()) do
      retained = retained(socket.assigns.decision_page.decisions, page.decisions)
      rows = page.decisions ++ retained
      slots = Map.new(rows, &{&1.decision_id, slot(&1, socket.assigns.id)})
      partial? = page.partial_results? or is_binary(page.pagination.next_cursor)

      assign(socket,
        selected_decision: Enum.find(rows, &(&1.decision_id == socket.assigns.selected_decision_id)),
        decision_page: %{page | decisions: rows},
        command_slots: slots,
        commands_error: if(partial?, do: "Some Commands are unavailable. Open the Commands list for more.")
      )
    else
      {:error, :no_subject} -> socket
      {:error, _reason} -> assign(socket, :commands_error, "Commands unavailable. Open the Commands list to retry.")
    end
  catch
    :exit, _reason -> assign(socket, :commands_error, "Commands unavailable. Open the Commands list to retry.")
  end

  defp subject(id) do
    case History.worker_identity(id) do
      {:ok, identity} -> {:ok, %{"ticket" => identity.identifier}}
      _ -> if id == Ref.conversation_id(Ref.executor()), do: {:ok, %{"requester" => "executor"}}, else: {:error, :no_subject}
    end
  end

  defp retained(previous, current) do
    ids = MapSet.new(current, & &1.decision_id)
    previous |> Enum.reject(&MapSet.member?(ids, &1.decision_id)) |> Enum.flat_map(&detail/1)
  end

  defp detail(row) do
    case DecisionProvider.detail(row.decision_id, options()) do
      {:ok, %{decision: decision}} -> [decision]
      {:error, _reason} -> []
    end
  end

  defp slot(command, conversation) do
    case History.command_anchor(command.decision_id) do
      {:ok, %{conversation_id: ^conversation} = anchor} -> card_slot(command, anchor)
      _ -> card_slot(command, nil)
    end
  end

  @spec card_slot(map(), map() | nil) :: {:at_pos, pos_integer()} | :pinned_top | :link_only
  def card_slot(_command, %{pos: pos}) when is_integer(pos) and pos > 0, do: {:at_pos, pos}
  def card_slot(_command, _anchor), do: :pinned_top

  @spec handle(String.t(), map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle(event, params, socket) do
    id = params["decision_id"] || params["decision-id"]
    row = Enum.find(socket.assigns.decision_page.decisions, &(&1.decision_id == id))

    if EndpointConfig.get(:dashboard_writable) == true and row do
      socket
      |> assign(selected_decision: row, selected_decision_id: id)
      |> then(fn s -> DecisionEvents.handle(event, params, s, &reload/1) end)
      |> assign(selected_decision: nil, selected_decision_id: nil)
      |> Paging.refresh_entries()
    else
      socket
    end
  end

  defp options, do: [decision_store: EndpointConfig.get(:decision_store) || Aiur.Commands.default_store()]
end
