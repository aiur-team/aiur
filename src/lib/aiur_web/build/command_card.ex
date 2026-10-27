defmodule AiurWeb.Build.CommandCard do
  @moduledoc """
  Server side of the ticket modal's Command answer card (MP-E8-C11-T08).

  The card reads the open Command of the modal's ticket through
  `DecisionCommands` and answers it through `DecisionCommands.record_answer/4`,
  the same durable, versioned and idempotent path as the Commands page. The
  store decides whether a card shows; the agent state only selects the
  "cannot load" card when the two sources disagree.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_event: 3]
  alias AiurWeb.OperatorControlCenter.DecisionCommands

  @read_only "Read-only dashboard"
  @waiting "This agent is waiting on a Command this page cannot load."
  @unconfirmed "This Command cannot be loaded right now. Its outcome is not confirmed."
  @answered ~w(decided acknowledged resolved)a
  @closed %{expired: {"expired", "This Command expired."}, dismissed: {"dismissed", "Closed without an answer."}, moot: {"moot", "No longer needed."}}

  @type read :: {:open, map()} | {:settled, map()} | :none | {:unavailable, atom()}

  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket), do: assign(socket, decision_actions: %{}, selected_decision: nil, selected_decision_id: nil, command_card: nil)

  @spec clear(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def clear(socket), do: init(socket)

  @doc "Loads the card for the pinned conversation and pushes it. Past tickets never load one."
  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load(socket) do
    socket = clear(socket)

    case socket.assigns[:conversation_ref] do
      %{id: id, closed?: false} = ref ->
        socket
        |> assign(command_card: %{ticket: id, agent_state: get_in(ref, [:row, "agent", "state"]), card: nil})
        |> reload()
        |> push()

      _ref ->
        socket
    end
  end

  @doc "Re-reads the store after a write; stores the card without pushing (the click reply carries it)."
  @spec reload(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reload(%{assigns: %{command_card: %{} = state}} = socket) do
    shown = socket.assigns.selected_decision_id
    read = read(state.ticket, shown)
    card = payload(read, shown, %{agent_state: state.agent_state, writable: socket.assigns[:writable] == true})

    {selected, selected_id} =
      case read do
        {:open, row} -> {row, row.decision_id}
        _other -> {nil, card && card[:decision_id]}
      end

    assign(socket, selected_decision: selected, selected_decision_id: selected_id, command_card: %{state | card: card})
  end

  def reload(socket), do: socket

  @doc "Decision signal or tick: re-reads and pushes only a changed card."
  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(%{assigns: %{command_card: %{card: before}}} = socket) do
    socket = reload(socket)
    if socket.assigns.command_card.card == before, do: socket, else: push(socket)
  end

  def refresh(socket), do: socket

  @doc "The click reply for `decision_id`, read from `decision_actions` after `record_answer/4`."
  @spec reply(Phoenix.LiveView.Socket.t(), String.t()) :: {map(), Phoenix.LiveView.Socket.t()}
  def reply(socket, decision_id) do
    action = Map.get(socket.assigns.decision_actions, decision_id, %{})
    card = socket.assigns.command_card && socket.assigns.command_card.card

    cond do
      Map.has_key?(action, :notice) -> accepted(socket, decision_id, card)
      settled?(card, decision_id) -> {%{status: "settled", message: action[:error], card: card}, socket}
      true -> {%{status: "error", message: action[:error] || "The command was rejected.", card: card}, socket}
    end
  end

  # After an accepted answer the operator knows the outcome: the reply carries the
  # next open Command or nothing, and the agent state of the opened row is stale.
  defp accepted(socket, decision_id, card) do
    {text, at_ms, action_id} =
      case DecisionCommands.command_detail(decision_id) do
        {:ok, %{answer: %{} = answer} = row} -> {answer_text(row, answer), millis(answer.accepted_at), answer.action_id}
        _unreadable -> {"Answered", nil, nil}
      end

    card = if match?(%{state: "open"}, card), do: card, else: nil

    socket =
      assign(socket,
        selected_decision_id: card && card.decision_id,
        command_card: socket.assigns.command_card && %{socket.assigns.command_card | card: card, agent_state: nil}
      )

    {%{status: "accepted", text: text, at_ms: at_ms, action_id: action_id, card: card}, socket}
  end

  defp settled?(%{decision_id: id, state: state}, id), do: state == "settled"

  defp settled?(_card, decision_id) do
    match?({:ok, %{open?: false}}, DecisionCommands.command_detail(decision_id))
  end

  @doc false
  @spec read(String.t(), String.t() | nil) :: read()
  def read(ticket, shown) do
    case DecisionCommands.ticket_command(ticket) do
      {:open, row} -> {:open, row}
      other when is_binary(shown) -> shown_read(shown, other)
      other -> other
    end
  end

  # A card that was showing never vanishes on a failed read: its own detail
  # decides whether it settled or its outcome is unknown.
  defp shown_read(shown, _open_read) do
    case DecisionCommands.command_detail(shown) do
      {:ok, %{open?: true} = row} -> {:open, row}
      {:ok, row} -> {:settled, row}
      {:unavailable, reason} -> {:unavailable, reason}
    end
  end

  @doc "Builds the card payload: a pure function of the read, the shown decision and the context."
  @spec payload(read(), String.t() | nil, %{agent_state: String.t() | nil, writable: boolean()}) :: map() | nil
  def payload({:open, row}, _shown, %{writable: writable}) do
    base(row)
    |> Map.merge(%{state: "open", version: row.version, writable: writable, disabled_reason: if(writable, do: nil, else: @read_only)})
  end

  def payload({:settled, row}, _shown, _context) do
    {kind, text} = settled_text(row)
    at_ms = if kind == "answered", do: millis(row.answer && row.answer.accepted_at), else: nil
    option_id = if kind == "answered", do: row.answer && row.answer.selected_option_id, else: nil
    base(row) |> Map.merge(%{state: "settled", kind: kind, option_id: option_id, text: text, at_ms: at_ms})
  end

  def payload({:unavailable, _reason}, shown, _context) when is_binary(shown),
    do: %{state: "unavailable", decision_id: shown, text: @unconfirmed, href: "/commands"}

  def payload(_none_or_unavailable, _shown, %{agent_state: "command"}),
    do: %{state: "unavailable", decision_id: nil, text: @waiting, href: "/commands"}

  def payload(_none_or_unavailable, _shown, _context), do: nil

  defp base(row) do
    recommended = get_in(row, [:recommendation, :option_id])

    %{
      decision_id: row.decision_id,
      question: row.question,
      options: Enum.map(row.options || [], &%{id: &1.id, label: &1.label, title: &1[:description], recommended: recommended != nil and &1.id == recommended})
    }
  end

  defp settled_text(%{decision_status: status} = row) when status in @answered do
    case row.answer do
      %{} = answer -> {"answered", answer_text(row, answer)}
      nil -> {"answered", "Answered"}
    end
  end

  defp settled_text(%{decision_status: status}) when is_map_key(@closed, status), do: Map.fetch!(@closed, status)
  defp settled_text(_row), do: {"closed", "This Command is no longer open."}

  defp answer_text(_row, %{selected_option_id: nil, custom_response: response}) when is_binary(response), do: "Answered with a custom response"

  defp answer_text(row, %{selected_option_id: id}) when is_binary(id) do
    case Enum.find(row.options || [], &(&1.id == id)) do
      %{label: label} when is_binary(label) -> "Answered: " <> label
      _removed -> "Answered: option " <> id
    end
  end

  defp answer_text(_row, _answer), do: "Answered"

  defp millis(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
  defp millis(_unknown), do: nil

  defp push(%{assigns: %{command_card: %{ticket: ticket, card: card}}} = socket),
    do: push_event(socket, "modal:command", %{ticket: ticket, card: card})
end
