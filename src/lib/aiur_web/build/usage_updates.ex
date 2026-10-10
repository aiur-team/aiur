defmodule AiurWeb.Build.UsageUpdates do
  @moduledoc false
  import Phoenix.Component, only: [assign: 2]
  alias Aiur.ProviderMeterRefresh
  alias AiurWeb.Build.{Payload, Protocol, Read, Usage}
  alias AiurWeb.Endpoint

  @ticks %{build_usage_github_tick: 15_000, build_usage_elevenlabs_tick: 60_000}

  @spec init(Phoenix.LiveView.Socket.t(), boolean()) :: Phoenix.LiveView.Socket.t()
  def init(socket, connected) do
    timers = if connected and Read.source_opts(socket)[:financial] != :locked, do: Map.new(@ticks, fn {tick, ms} -> {tick, Process.send_after(self(), tick, ms)} end)
    assign(socket, build_usage_timers: timers, build_usage_last: nil, build_usage_pending: nil, build_usage_flush_scheduled: false)
  end

  @spec queue(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def queue(%{assigns: %{build_usage_timers: nil}} = socket, _message), do: socket

  def queue(socket, message) do
    unless socket.assigns.build_usage_flush_scheduled do
      case Endpoint.config(:build_usage_flush_timer) do
        timer when is_function(timer, 3) -> timer.(self(), :build_usage_flush, 250)
        _ -> Process.send_after(self(), :build_usage_flush, 250)
      end
    end

    assign(socket, build_usage_pending: message, build_usage_flush_scheduled: true)
  end

  @spec flush(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def flush(socket) do
    message = socket.assigns.build_usage_pending
    socket = assign(socket, build_usage_pending: nil, build_usage_flush_scheduled: false)
    if message, do: update(socket, reload: message), else: socket
  end

  @spec tick(Phoenix.LiveView.Socket.t(), atom()) :: Phoenix.LiveView.Socket.t()
  def tick(%{assigns: %{build_usage_timers: nil}} = socket, _tick), do: socket

  def tick(socket, tick) do
    socket = update(socket, [])

    if socket.assigns.build_usage_timers do
      Process.cancel_timer(socket.assigns.build_usage_timers[tick])
      ref = Process.send_after(self(), tick, Map.fetch!(@ticks, tick))
      assign(socket, build_usage_timers: Map.put(socket.assigns.build_usage_timers, tick, ref))
    else
      socket
    end
  end

  @spec watch(Phoenix.LiveView.Socket.t(), :start | :stop) :: Phoenix.LiveView.Socket.t()
  def watch(socket, :start) do
    if Read.source_opts(socket)[:financial] != :locked, do: ProviderMeterRefresh.watching_started()
    socket
  end

  def watch(socket, :stop) do
    ProviderMeterRefresh.watching_stopped()
    socket
  end

  defp update(socket, read_opts) do
    opts = Read.source_opts(socket)

    case opts[:financial] do
      :locked ->
        revoke(socket, opts)

      financial ->
        usage = source().read(financial, read_opts) |> Payload.scrub()

        if usage == socket.assigns.build_usage_last do
          socket
        else
          Protocol.changes(socket, %{now: System.system_time(:millisecond), upsert: [], remove: [], set: %{usage: usage}}, opts)
        end
    end
  end

  defp revoke(socket, opts) do
    Enum.each(socket.assigns.build_usage_timers || %{}, fn {_tick, ref} -> Process.cancel_timer(ref) end)
    ProviderMeterRefresh.watching_stopped()

    socket
    |> assign(build_usage_last: nil, build_usage_timers: nil, build_usage_pending: nil, build_usage_flush_scheduled: false)
    |> Protocol.changes(%{resync: true}, opts)
  end

  defp source, do: Endpoint.config(:build_usage_source) || Usage
end
