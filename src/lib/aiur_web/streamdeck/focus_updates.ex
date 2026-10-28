defmodule AiurWeb.Streamdeck.FocusUpdates do
  @moduledoc "One owned, focus-correlated projection task keeps channel input responsive."

  alias AiurWeb.{EndpointConfig, StreamdeckLogs}
  alias AiurWeb.StreamdeckChannel.CommandAnswers
  import Phoenix.Socket, only: [assign: 2]

  @spec refresh(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def refresh(socket) do
    socket = stop(socket)
    %{focused_agent: id, focus_token: token} = socket.assigns
    owner = self()
    load = EndpointConfig.get(:streamdeck_focus_load_fun) || (&load/2)

    task =
      Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn ->
        logs = load.(:logs, id)
        send(owner, {:streamdeck_focus_logs, id, token, logs})
        load.(:commands, id)
      end)

    assign(socket, focus_task: %{task: task, id: id, token: token, logs: true, commands: true})
  end

  @spec logs(Phoenix.Socket.t(), String.t(), reference(), map()) :: Phoenix.Socket.t()
  def logs(%{assigns: %{focused_agent: id, focus_token: token, focus_task: %{id: id, token: token, logs: true}}} = socket, id, token, payload) do
    Phoenix.Channel.push(socket, "logs", payload)
    socket
  end

  def logs(socket, _id, _token, _payload), do: socket

  @spec complete(Phoenix.Socket.t(), map()) :: Phoenix.Socket.t()
  def complete(%{assigns: %{focus_task: %{task: task, id: id, token: token, commands: pending}}} = socket, payload) do
    Process.demonitor(task.ref, [:flush])
    if pending and socket.assigns.focused_agent == id and socket.assigns.focus_token == token, do: Phoenix.Channel.push(socket, "commands", payload)
    assign(socket, focus_task: nil)
  end

  @spec supersede(Phoenix.Socket.t(), :logs | :commands) :: Phoenix.Socket.t()
  def supersede(%{assigns: %{focus_task: task}} = socket, kind) when is_map(task) and kind in [:logs, :commands],
    do: assign(socket, focus_task: Map.put(task, kind, false))

  def supersede(socket, _kind), do: socket

  @spec failed(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def failed(socket), do: complete(socket, %{"identifier" => socket.assigns.focus_task.id, "unavailable" => true})

  @spec stop(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def stop(%{assigns: %{focus_task: %{task: task}}} = socket) do
    Task.shutdown(task, :brutal_kill)
    assign(socket, focus_task: nil)
  end

  def stop(socket), do: socket

  defp load(:logs, id), do: id |> StreamdeckLogs.load() |> StreamdeckLogs.wire()
  defp load(:commands, id), do: CommandAnswers.commands_projection(id)
end
