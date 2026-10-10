defmodule AiurWeb.Build.Protocol do
  @moduledoc false
  import Phoenix.Component, only: [assign: 2]
  alias AiurWeb.Build.{DataSource, Payload, Read}
  require Logger

  @resync_interval_ms 2_000

  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket) do
    zone =
      case Phoenix.LiveView.get_connect_params(socket) do
        %{"time_zone" => zone} when is_binary(zone) and zone != "" -> zone
        _ -> "Etc/UTC"
      end

    assign(socket,
      build_epoch: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      build_generation: 0,
      build_resynced: false,
      build_read_at: nil,
      build_time_zone: zone,
      build_index_generation: nil,
      build_history: nil,
      build_source: DataSource.source(),
      writable: writable?()
    )
  end

  @spec store(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def store(socket, data) do
    data = Payload.scrub(data)
    assign(socket, build_snapshot: data, build_history: data["history"], build_index_generation: data["index_generation"])
  end

  @spec resync(Phoenix.LiveView.Socket.t(), keyword()) :: {:reply, map(), Phoenix.LiveView.Socket.t()}
  def resync(socket, opts) do
    a = socket.assigns
    now = clock()
    cached? = a.build_state == :ready and a.build_generation == 0 and not a.build_resynced
    throttled? = is_integer(a.build_read_at) and now - a.build_read_at < @resync_interval_ms

    cond do
      cached? ->
        snapshot_reply({:ok, a.build_snapshot}, socket, opts)

      throttled? ->
        # build_snapshot is not folded with later diffs, so serving it would stamp stale rows as current.
        :telemetry.execute([:aiur, :build, :resync_throttled], %{count: 1}, %{})
        {:reply, Payload.error(:throttled), socket}

      true ->
        result = Read.safe_read(fn -> DataSource.call(a.build_source, :snapshot, [opts]) end)
        snapshot_reply(result, assign(socket, build_read_at: now), opts)
    end
  end

  @spec earlier(Phoenix.LiveView.Socket.t(), map(), keyword()) :: {:reply, map(), Phoenix.LiveView.Socket.t()}
  def earlier(socket, %{"before" => before} = params, opts) when is_integer(before) and before > 0 do
    days = Map.get(params, "days", 1)

    if before <= System.system_time(:millisecond) + 86_400_000 and is_integer(days) and days in 1..31 do
      result = Read.safe_read(fn -> DataSource.call(socket.assigns.build_source, :earlier, [before, opts[:time_zone], Keyword.put(opts, :days, days)]) end)
      page_reply(result, socket)
    else
      {:reply, Payload.error(:invalid_params), socket}
    end
  end

  def earlier(socket, _params, _opts), do: {:reply, Payload.error(:invalid_params), socket}

  @spec changes(Phoenix.LiveView.Socket.t(), map(), keyword()) :: Phoenix.LiveView.Socket.t()
  def changes(socket, changes, opts) when is_map(changes) do
    changes = Payload.scrub(changes)

    cond do
      changes["resync"] == true -> restart(socket)
      stale?(changes, socket.assigns.build_index_generation) -> socket
      is_list(changes["upsert"]) and is_list(changes["remove"]) and is_map(changes["set"]) -> push_change(socket, changes, opts)
      true -> restart(socket)
    end
  end

  def changes(socket, _changes, _opts), do: restart(socket)

  defp snapshot_reply({:ok, data}, socket, opts) do
    data = data |> Payload.scrub() |> access(opts)
    message = Payload.snapshot(data, socket.assigns.build_epoch, socket.assigns.build_generation)

    case validate(message) do
      :ok ->
        warn_size(message)
        {:reply, message, socket |> store(data) |> assign(build_resynced: true)}

      :error ->
        {:reply, Payload.error(:unavailable), socket}
    end
  end

  defp snapshot_reply(_error, socket, _opts), do: {:reply, Payload.error(:unavailable), socket}

  defp page_reply({:ok, page}, socket) do
    message = Payload.earlier(page, socket.assigns.build_epoch, socket.assigns.build_generation)
    if validate(message) == :ok, do: {:reply, message, assign(socket, build_history: message["history"])}, else: {:reply, Payload.error(:unavailable), socket}
  end

  defp page_reply(_error, socket), do: {:reply, Payload.error(:unavailable), socket}

  defp push_change(socket, changes, opts) do
    changes = if opts[:financial] == :locked, do: update_in(changes["set"], &Map.delete(&1, "usage")), else: changes
    generation = socket.assigns.build_generation + 1
    message = Payload.diff(changes, socket.assigns.build_epoch, generation, socket.assigns.build_history)

    if validate(message) == :ok do
      socket
      |> assign(
        build_generation: generation,
        build_history: Map.get(message["set"], "history", socket.assigns.build_history),
        build_index_generation: Map.get(changes, "index_generation", socket.assigns.build_index_generation)
      )
      |> Phoenix.LiveView.push_event("build-diff", message)
    else
      restart(socket)
    end
  end

  defp restart(socket) do
    generation = socket.assigns.build_generation + 2
    message = Payload.diff(%{now: System.system_time(:millisecond), upsert: [], remove: [], set: %{}}, socket.assigns.build_epoch, generation, socket.assigns.build_history)
    socket |> assign(build_generation: generation, build_index_generation: nil) |> Phoenix.LiveView.push_event("build-diff", message)
  end

  defp access(data, opts) do
    data = Map.put(data, "writable", writable?())
    if opts[:financial] == :locked, do: Map.put(data, "usage", Read.locked_usage()), else: data
  end

  defp validate(message) do
    case Payload.validate(message) do
      :ok ->
        :ok

      {:error, paths} ->
        Logger.warning("build payload invalid paths=#{inspect(paths)}")
        :error
    end
  end

  defp warn_size(message) do
    size = Payload.bytes(message)

    if size > 524_288 do
      counts = Map.new(message["sections"], fn {key, rows} -> {key, length(rows)} end)
      Logger.warning("build snapshot oversized bytes=#{size} rows=#{inspect(counts)}")
    end
  end

  defp stale?(%{"index_generation" => generation}, current) when is_integer(generation) and is_integer(current), do: generation <= current
  defp stale?(_changes, _current), do: false
  defp clock, do: AiurWeb.Endpoint.config(:build_resync_clock, &System.monotonic_time/1).(:millisecond)
  defp writable?, do: AiurWeb.Endpoint.config(:dashboard_writable) == true
end
