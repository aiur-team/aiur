defmodule AiurWeb.BuildQueue.Runtime do
  @moduledoc "Read-only local queue refreshes for the Build Order panel."
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, start_async: 3]
  alias Aiur.{AlertFeed, BuildQueue}
  alias Phoenix.LiveView.Socket

  @spec mount(Socket.t()) :: Socket.t()
  def mount(socket) do
    socket = socket |> assign(:queue_view, nil) |> assign(:queue_loading, false) |> assign(:queue_refresh_pending, false) |> assign(:queue_refreshed_at, 0)

    if connected?(socket) do
      socket =
        AiurWeb.RefreshRelay.mount(
          socket,
          fn ->
            Phoenix.PubSub.subscribe(Aiur.PubSub, "build_queue:changed")
            Phoenix.PubSub.subscribe(Aiur.PubSub, "build_progress")
          end,
          [:build_queue_changed, :build_progress_changed]
        )

      refresh(socket)
    else
      socket
    end
  end

  @spec schedule(Socket.t()) :: Socket.t()
  def schedule(%{assigns: %{queue_refresh_pending: true}} = socket), do: socket

  def schedule(socket) do
    Process.send_after(self(), :refresh_build_queue, 500)
    assign(socket, :queue_refresh_pending, true)
  end

  @spec tick(Socket.t()) :: Socket.t()
  def tick(socket) do
    if System.monotonic_time(:millisecond) - socket.assigns.queue_refreshed_at >= 5_000, do: schedule(socket), else: socket
  end

  @spec refresh(Socket.t()) :: Socket.t()
  def refresh(%{assigns: %{queue_loading: true}} = socket), do: socket |> assign(:queue_refresh_pending, false) |> schedule()

  def refresh(socket) do
    reader = Application.get_env(:aiur, :build_queue_dashboard_reader, &read/0)

    socket
    |> assign(:queue_loading, true)
    |> assign(:queue_refresh_pending, false)
    |> start_async(:build_queue_view, reader)
  end

  @spec complete(Socket.t(), term()) :: Socket.t()
  def complete(socket, result) do
    view =
      case result do
        {:ok, %{model: %{sources: sources, queues: queues}, attentions: attentions} = view} when is_map(sources) and is_list(queues) and is_list(attentions) -> view
        _ -> %{model: %{status: :unknown, sources: %{}, queues: []}, attentions: []}
      end

    socket |> assign(:queue_view, view) |> assign(:queue_loading, false) |> assign(:queue_refreshed_at, System.monotonic_time(:millisecond))
  end

  @spec read() :: map()
  def read do
    model = BuildQueue.show()
    attentions = AlertFeed.list() |> Enum.filter(&String.contains?(Map.get(&1, "topic", ""), ".queue.attention."))
    %{model: model, attentions: attentions}
  end

  @spec recent_attentions([map()], DateTime.t()) :: [map()]
  def recent_attentions(attentions, now) do
    Enum.filter(attentions, &visible_attention?(&1, now))
  end

  defp visible_attention?(%{"needs_attention" => true}, _now), do: true

  defp visible_attention?(%{"timestamp" => timestamp}, now) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, observed, _} -> DateTime.diff(now, observed, :second) in 0..60
      _ -> false
    end
  end

  defp visible_attention?(_alert, _now), do: false
end
