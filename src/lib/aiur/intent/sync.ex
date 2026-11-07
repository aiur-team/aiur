defmodule Aiur.Intent.Sync do
  @moduledoc """
  Pushes the outbox to Postgres and pulls shared changes by `seq`. Started only when the
  coordination store is configured; `apply_remote/2` works without it.

  Applying a pulled or directly delivered change never writes the outbox.
  """
  use GenServer

  require Logger

  alias Aiur.Instance.LeaseStore
  alias Aiur.Intent.{Change, Store}

  @page 500
  @min_backoff 5_000
  @max_backoff 60_000
  @nudge_ms 50

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Coalesced request for a sync soon; a no-op when Sync is not running."
  @spec nudge(GenServer.server()) :: :ok
  def nudge(server \\ __MODULE__) do
    if pid = GenServer.whereis(server), do: send(pid, :nudge)
    :ok
  end

  @spec sync_once(GenServer.server()) :: :ok | {:error, term()}
  def sync_once(server \\ __MODULE__), do: GenServer.call(server, :sync_once, 30_000)

  @doc "Bounded synchronous pull (never pushes)."
  @spec pull(keyword()) :: :ok | {:error, term()}
  def pull(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout_ms, 5_000)

    if GenServer.whereis(server), do: GenServer.call(server, {:pull, timeout}, timeout + 1_000), else: {:error, :disabled}
  end

  @doc "One change delivered by a direct control call. Validated, deduped, never queued for publishing."
  @spec apply_remote(Change.t(), keyword()) :: {:ok, :applied | :duplicate} | {:error, atom()}
  def apply_remote(%Change{} = change, opts \\ []) do
    store = Keyword.get(opts, :store, Store)

    with :ok <- Change.validate(change) do
      case Store.append_remote(store, [change]) do
        {:ok, 0} -> {:ok, :duplicate}
        {:ok, _} -> {:ok, :applied}
        {:error, _} -> {:error, :store_write_failed}
      end
    end
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    state = %{
      store: Keyword.get(opts, :store, Store),
      publish_fun: Keyword.get(opts, :publish_fun, &LeaseStore.publish_intent_changes/1),
      pull_fun: Keyword.get(opts, :pull_fun, &LeaseStore.intent_changes_since/2),
      interval: Keyword.get(opts, :interval_ms, 5_000),
      backoff: 0,
      timer: nil,
      needs_pull: true,
      last_ok_at: nil,
      last_error: nil,
      skipped_invalid: 0
    }

    {:ok, schedule(state, state.interval)}
  end

  @impl true
  def handle_call(:sync_once, _from, s) do
    {result, s} = run(s)
    {:reply, result, s}
  end

  def handle_call({:pull, timeout}, _from, s) do
    {result, s} = bounded_pull(s, timeout)
    {:reply, result, s}
  end

  def handle_call(:status, _from, s) do
    {:reply,
     %{
       outbox: length(Store.outbox(s.store)),
       last_ok_at: s.last_ok_at,
       last_error: s.last_error,
       pull_cursor: Store.pull_cursor(s.store),
       needs_pull: s.needs_pull,
       skipped_invalid: s.skipped_invalid
     }, s}
  end

  @impl true
  def handle_info(:sync, s) do
    {_result, s} = run(%{s | timer: nil})
    {:noreply, s}
  end

  def handle_info(:nudge, s), do: {:noreply, schedule(s, @nudge_ms)}
  def handle_info(_other, s), do: {:noreply, s}

  defp run(s) do
    with {:ok, s} <- push(s), {:ok, s} <- pull_all(s) do
      {:ok, schedule(%{s | backoff: 0, last_ok_at: DateTime.utc_now(), last_error: nil}, s.interval)}
    else
      {:error, reason, s} -> fail(s, reason)
    end
  end

  defp fail(s, reason) do
    backoff = s.backoff |> Kernel.*(2) |> max(@min_backoff) |> min(@max_backoff)
    {{:error, reason}, schedule(%{s | backoff: backoff, needs_pull: true, last_error: tag(reason)}, backoff)}
  end

  defp tag({:store_unavailable, _}), do: :store_unavailable
  defp tag(reason) when is_atom(reason), do: reason
  defp tag(_), do: :unknown

  defp push(s) do
    case Store.outbox(s.store, 100) do
      [] -> {:ok, s}
      batch -> publish(s, batch)
    end
  end

  defp publish(s, batch) do
    with {:ok, ids} <- normalize(s.publish_fun.(batch)),
         :ok <- Store.ack_outbox(s.store, ids) do
      if length(batch) == 100, do: push(s), else: {:ok, s}
    else
      {:error, reason} -> {:error, reason, s}
    end
  end

  defp pull_all(s) do
    cursor = Store.pull_cursor(s.store)

    case normalize(s.pull_fun.(cursor, @page)) do
      {:ok, rows} -> apply_page(s, rows, cursor)
      {:error, reason} -> {:error, reason, s}
    end
  end

  defp apply_page(s, rows, cursor) do
    {valid, invalid} = Enum.split_with(rows, &(Change.validate(&1) == :ok))
    max_seq = rows |> Enum.map(& &1.seq) |> Enum.max(fn -> cursor end)
    s = %{s | skipped_invalid: s.skipped_invalid + length(invalid)}

    case Store.append_remote(s.store, valid, cursor: max_seq) do
      {:ok, _} -> next_page(s, length(rows), max_seq > cursor)
      {:error, reason} -> {:error, reason, s}
    end
  end

  defp next_page(s, @page, true), do: pull_all(s)
  defp next_page(s, _count, _advanced), do: {:ok, %{s | needs_pull: false}}

  defp normalize(:disabled), do: {:error, :disabled}
  defp normalize(other), do: other

  defp bounded_pull(s, timeout) do
    task = Task.async(fn -> pull_all(s) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, s2}} -> {:ok, %{s2 | last_error: nil}}
      {:ok, {:error, reason, s2}} -> {{:error, reason}, %{s2 | needs_pull: true, last_error: tag(reason)}}
      _ -> {{:error, :timeout}, %{s | needs_pull: true, last_error: :timeout}}
    end
  end

  defp schedule(s, delay) do
    if s.timer, do: Process.cancel_timer(s.timer)
    %{s | timer: Process.send_after(self(), :sync, delay)}
  end
end
