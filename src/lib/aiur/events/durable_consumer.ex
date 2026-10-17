defmodule Aiur.Events.DurableConsumer do
  @moduledoc """
  Subscribe, replay from a persisted cursor, then go live, at-least-once.

  The source is subscribed first so nothing published during replay is lost,
  then records after the persisted cursor are replayed in batches, then live
  records are applied in order. The cursor is persisted only after
  `handle_record/2` returns `{:ok, _}`, so a crash redelivers that record.

  Cursors are dense per-source positions (see `Aiur.Events.DurableConsumer.Source`),
  which is why this is not used with event ids. A live record past `cursor + 1`
  re-enters catch-up instead of being applied out of order; a handler error or
  unavailable source retries after `retry_ms`.
  """

  # aiur:event-bus-boundary-member

  use GenServer

  alias Aiur.JsonStore

  require Logger

  @type opts :: [
          name: GenServer.name(),
          source: {module(), term()},
          handler: {module(), term()},
          cursor_path: Path.t(),
          replay_batch: pos_integer(),
          retry_ms: non_neg_integer()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @impl true
  def init(opts) do
    {smod, sopts} = Keyword.fetch!(opts, :source)
    {hmod, hstate} = Keyword.fetch!(opts, :handler)
    path = Keyword.fetch!(opts, :cursor_path)

    :ok = smod.subscribe(sopts, self())

    state = %{
      smod: smod,
      sopts: sopts,
      hmod: hmod,
      hs: hstate,
      path: path,
      batch: Keyword.get(opts, :replay_batch, 500),
      retry_ms: Keyword.get(opts, :retry_ms, 5_000),
      cursor: load_cursor(path),
      mode: :catching_up,
      outage: false
    }

    {:ok, state, {:continue, :catch_up}}
  end

  @impl true
  def handle_continue(:catch_up, state), do: {:noreply, catch_up(state)}

  @impl true
  def handle_info(:catch_up, state), do: {:noreply, catch_up(state)}

  def handle_info({:durable_record, record}, %{mode: :live} = state) do
    pos = state.smod.position(record)

    cond do
      pos <= state.cursor -> {:noreply, state}
      pos == state.cursor + 1 -> {:noreply, deliver_live(state, record)}
      true -> {:noreply, catch_up(state)}
    end
  end

  # Not live: catch-up will read this record from the source.
  def handle_info({:durable_record, _record}, state), do: {:noreply, state}

  defp deliver_live(state, record) do
    case deliver(state, record) do
      {:ok, state} -> state
      {:error, state} -> retry(state)
    end
  end

  defp catch_up(state) do
    case state.smod.replay(state.sopts, state.cursor, state.batch) do
      {:ok, records} ->
        case deliver_all(state, records) do
          {:ok, state} when length(records) < state.batch -> %{state | mode: :live, outage: false}
          {:ok, state} -> catch_up(state)
          {:error, state} -> retry(state)
        end

      {:reset, oldest} ->
        {:ok, hs} = state.hmod.handle_reset(oldest, state.hs)
        catch_up(persist(%{state | hs: hs}, max(oldest - 1, 0)))

      {:error, reason} ->
        unavailable(state, reason)
    end
  end

  defp deliver_all(state, records) do
    Enum.reduce_while(records, {:ok, state}, fn record, {:ok, state} ->
      case deliver(state, record) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  defp deliver(state, record) do
    pos = state.smod.position(record)

    if pos <= state.cursor do
      {:ok, state}
    else
      case state.hmod.handle_record(record, state.hs) do
        {:ok, hs} ->
          {:ok, persist(%{state | hs: hs}, pos)}

        {:error, reason} ->
          Logger.warning("durable consumer handler failed at #{pos}: #{inspect(reason)}")
          {:error, state}
      end
    end
  end

  defp unavailable(%{outage: true} = state, _reason), do: retry(state)

  defp unavailable(state, reason) do
    {:ok, hs} = state.hmod.handle_unavailable(reason, state.hs)
    retry(%{state | hs: hs, outage: true})
  end

  defp retry(state) do
    Process.send_after(self(), :catch_up, state.retry_ms)
    %{state | mode: :waiting}
  end

  defp persist(state, cursor) do
    JsonStore.write!(state.path, %{"cursor" => cursor})
    %{state | cursor: cursor}
  end

  # A missing or corrupt cursor replays from the start: redelivery, never a skip.
  defp load_cursor(path) do
    case JsonStore.read(path) do
      {:ok, %{"cursor" => n}} when is_integer(n) and n >= 0 ->
        n

      {:ok, nil} ->
        0

      other ->
        Logger.warning("durable consumer cursor unreadable at #{path}: #{inspect(other)}; replaying from 0")
        0
    end
  end
end
