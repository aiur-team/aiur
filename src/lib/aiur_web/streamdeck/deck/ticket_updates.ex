defmodule AiurWeb.Streamdeck.Deck.TicketUpdates do
  @moduledoc "One asynchronous ticket read per channel, correlated to the current focus."
  import Phoenix.Socket, only: [assign: 2]
  alias AiurWeb.Streamdeck.Deck.TicketPage

  @spec refresh(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def refresh(%{assigns: %{focused_agent: nil}} = socket), do: socket
  def refresh(%{assigns: %{ticket_task: task}} = socket) when not is_nil(task), do: assign(socket, ticket_pending: true)

  def refresh(socket) do
    %{focused_agent: id, focus_token: token} = socket.assigns
    owner = self()

    task =
      Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn ->
        :ok = TicketPage.subscribe(owner)
        TicketPage.read(id)
      end)

    assign(socket, ticket_task: %{task: task, id: id, token: token}, ticket_pending: false)
  end

  @spec complete(Phoenix.Socket.t(), map()) :: Phoenix.Socket.t()
  def complete(%{assigns: %{ticket_task: %{task: task, id: id, token: token}}} = socket, dto) do
    Process.demonitor(task.ref, [:flush])
    if socket.assigns.focused_agent == id and socket.assigns.focus_token == token, do: Phoenix.Channel.push(socket, "ticket", dto)
    pending = socket.assigns.ticket_pending
    socket = assign(socket, ticket_task: nil, ticket_pending: false)
    if pending, do: refresh(socket), else: socket
  end

  @spec failed(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def failed(socket), do: complete(socket, TicketPage.unavailable(socket.assigns.ticket_task.id))

  @spec stop(Phoenix.Socket.t()) :: :ok
  def stop(%{assigns: %{ticket_task: %{task: task}}}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  def stop(_socket), do: :ok
end
