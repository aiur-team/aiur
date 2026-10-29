defmodule AiurWeb.Build.QueueAdd do
  @moduledoc "Single-flight queue additions from the build home issue view."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, start_async: 3]
  alias AiurWeb.{Build.Payload, EndpointConfig}

  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket), do: assign(socket, :queue_add_pending, MapSet.new())

  @spec open(Phoenix.LiveView.Socket.t(), term()) :: {:reply, map(), Phoenix.LiveView.Socket.t()}
  def open(socket, params) do
    cond do
      socket.assigns.writable != true or EndpointConfig.get(:dashboard_writable) != true ->
        {:reply, Payload.error(:read_only), socket}

      not valid?(params) ->
        {:reply, Payload.error(:invalid_params), socket}

      true ->
        enqueue(socket, params["id"])
    end
  end

  defp valid?(%{"id" => id}) when is_binary(id), do: Regex.match?(~r/\A[1-9][0-9]{0,9}\z/, id)
  defp valid?(_params), do: false

  defp enqueue(socket, id) do
    pending = socket.assigns.queue_add_pending

    socket =
      if MapSet.member?(pending, id) do
        socket
      else
        add = EndpointConfig.get(:build_queue_add_fun) || (&Aiur.BuildQueue.add/2)

        socket
        |> assign(:queue_add_pending, MapSet.put(pending, id))
        |> start_async({:queue_add, id}, fn -> add.([id], "default") end)
      end

    {:reply, Payload.scrub(%{v: 1, kind: "queue-add", id: id, state: "pending"}), socket}
  end

  @spec result(Phoenix.LiveView.Socket.t(), String.t(), term()) :: Phoenix.LiveView.Socket.t()
  def result(socket, id, result) do
    message = Map.merge(%{v: 1, kind: "queue-add-result", id: id}, outcome(result))

    socket
    |> assign(:queue_add_pending, MapSet.delete(socket.assigns.queue_add_pending, id))
    |> push_event("build-queue-add", Payload.scrub(message))
  end

  defp outcome({:ok, :ok}), do: %{ok: true}
  defp outcome({:ok, {:ok, _result}}), do: %{ok: true}
  defp outcome({:ok, {:error, {:already_queued, name}}}), do: %{ok: true, reason: "already_queued", queue: name}

  # Membership is persisted before marker writes, so a marker failure cannot be called a refused add.
  defp outcome({:ok, {:error, {:marker_write_failed, _failures}}}), do: %{ok: false, reason: "outcome_unknown"}
  defp outcome({:ok, {:error, :outcome_unknown}}), do: %{ok: false, reason: "outcome_unknown"}
  defp outcome({:exit, _reason}), do: %{ok: false, reason: "outcome_unknown"}

  defp outcome({:ok, {:error, reason}}) when reason in [:closed, :store_unavailable, :unsupported_tracker],
    do: %{ok: false, reason: Atom.to_string(reason)}

  defp outcome(_result), do: %{ok: false, reason: "refused"}
end
