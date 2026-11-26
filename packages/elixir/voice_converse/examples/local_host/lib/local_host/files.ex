defmodule LocalHost.Files do
  @moduledoc "Serialized outbox writes and incremental inbox/briefing polling."
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def subscribe(topic, pid), do: GenServer.call(__MODULE__, {:subscribe, topic, pid})
  def append(record), do: GenServer.call(__MODULE__, {:append, record})
  def poll, do: GenServer.call(__MODULE__, :poll)

  @impl true
  def init(opts) do
    state = %{
      subscribers: %{},
      offset: 0,
      tail: "",
      briefing: nil,
      interval: Keyword.get(opts, :interval, 500)
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_call({:subscribe, topic, pid}, _from, state) do
    if Enum.any?(state.subscribers, fn {_ref, subscriber} -> subscriber == {topic, pid} end) do
      {:reply, :ok, state}
    else
      monitor = Process.monitor(pid)
      subscribers = Map.put(state.subscribers, monitor, {topic, pid})
      {:reply, :ok, %{state | subscribers: subscribers}}
    end
  end

  def handle_call({:append, record}, _from, state) do
    result = File.write(LocalHost.path("outbox.ndjson"), Jason.encode!(record) <> "\n", [:append])
    reply = if result == :ok, do: {:ok, record.ref}, else: result
    {:reply, reply, state}
  end

  def handle_call(:poll, _from, state), do: {:reply, :ok, refresh(state)}

  @impl true
  def handle_info(:poll, state), do: {:noreply, state |> refresh() |> schedule()}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, monitor)}}

  defp schedule(state) do
    Process.send_after(self(), :poll, state.interval)
    state
  end

  defp refresh(state), do: state |> briefing() |> inbox()

  defp briefing(state) do
    content = File.read(LocalHost.path("briefing.md"))

    if content != state.briefing do
      Enum.each(state.subscribers, fn {_monitor, {topic, pid}} ->
        case topic do
          {:briefing, target} ->
            send(pid, {:briefing_updated, target, LocalHost.BriefingSource.brief(target)})

          _ ->
            :ok
        end
      end)
    end

    %{state | briefing: content}
  end

  defp inbox(state) do
    case File.open(LocalHost.path("inbox.ndjson"), [:read, :binary]) do
      {:ok, file} ->
        try do
          {:ok, size} = :file.position(file, :eof)
          offset = if size < state.offset, do: 0, else: state.offset
          {:ok, _pos} = :file.position(file, offset)
          consume(state, IO.binread(file, :eof), offset)
        after
          File.close(file)
        end

      {:error, :enoent} ->
        state

      {:error, reason} ->
        Logger.warning("local host inbox unavailable: #{inspect(reason)}")
        state
    end
  end

  defp consume(state, :eof, _offset), do: state

  defp consume(state, {:error, reason}, _offset) do
    Logger.warning("local host inbox read failed: #{inspect(reason)}")
    state
  end

  defp consume(state, chunk, offset) do
    tail = if offset == 0, do: "", else: state.tail
    lines = String.split(tail <> chunk, "\n")
    Enum.each(Enum.drop(lines, -1), &deliver(&1, state.subscribers))
    %{state | offset: offset + byte_size(chunk), tail: List.last(lines)}
  end

  defp deliver("", _subscribers), do: :ok

  defp deliver(line, subscribers) do
    case Jason.decode(line) do
      {:ok, %{"ref" => ref, "text" => text, "target" => target}}
      when is_binary(ref) and is_binary(text) ->
        Enum.each(subscribers, fn {_monitor, {topic, pid}} ->
          if topic == {:agent, target}, do: send(pid, {:agent_reply, ref, text})
        end)

      _ ->
        Logger.warning("local host ignored malformed inbox record")
    end
  end
end
