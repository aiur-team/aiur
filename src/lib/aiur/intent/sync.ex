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
  @table :aiur_intent_sync

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
        {:ok, []} ->
          {:ok, :duplicate}

        {:ok, fresh} ->
          notify(opts, fresh)
          {:ok, :applied}

        {:error, _} ->
          {:error, :store_write_failed}
      end
    end
  end

  # Hook for MPG-405: called once with exactly the newly appended changes, never for a duplicate.
  defp notify(opts, fresh) do
    hook = Keyword.get_lazy(opts, :on_remote_applied, fn -> configured_hook(Keyword.get(opts, :table, @table)) end)
    hook.(fresh)
    :ok
  end

  # Sync's own configured hook (published in its table), so a direct call fires what the pull path fires.
  defp configured_hook(table) do
    with true <- :ets.whereis(table) != :undefined, [{:hook, hook}] <- :ets.lookup(table, :hook) do
      hook
    else
      _ -> fn _ -> :ok end
    end
  end

  @doc """
  `:ok` straight from an ETS read when nothing needs pulling (or Sync is not running);
  otherwise a bounded pull. After a failure, `{:error, :recently_failed}` until the backoff passes.
  """
  @spec ensure_fresh(non_neg_integer(), keyword()) :: :ok | {:error, term()}
  def ensure_fresh(timeout_ms, opts \\ []) do
    table = Keyword.get(opts, :table, @table)

    with true <- :ets.whereis(table) != :undefined,
         [{:needs_pull, true}] <- :ets.lookup(table, :needs_pull) do
      [{:retry_at, retry_at}] = :ets.lookup(table, :retry_at)

      if System.monotonic_time(:millisecond) < retry_at,
        do: {:error, :recently_failed},
        else: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:pull, timeout_ms}, timeout_ms + 1_000)
    else
      _ -> :ok
    end
  catch
    :exit, _ -> {:error, :timeout}
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)
    :ets.new(table, [:named_table, :protected, read_concurrency: true])

    state = %{
      table: table,
      on_remote_applied: Keyword.get(opts, :on_remote_applied, fn _ -> :ok end),
      store: Keyword.get(opts, :store, Store),
      publish_fun: Keyword.get(opts, :publish_fun, &LeaseStore.publish_intent_changes/1),
      pull_fun: Keyword.get(opts, :pull_fun, &LeaseStore.intent_changes_since/3),
      interval: Keyword.get(opts, :interval_ms, 5_000),
      backoff: 0,
      timer: nil,
      last_ok_at: nil,
      last_error: nil,
      skipped_invalid: 0
    }

    :ets.insert(table, {:hook, state.on_remote_applied})
    flag(state, true, System.monotonic_time(:millisecond))
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
       needs_pull: needs_pull?(s),
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
      flag(s, false, System.monotonic_time(:millisecond))
      {:ok, schedule(%{s | backoff: 0, last_ok_at: DateTime.utc_now(), last_error: nil}, s.interval)}
    else
      {:error, reason, s} -> fail(s, reason)
    end
  end

  defp fail(s, reason) do
    s = failed(s, reason)
    {{:error, reason}, schedule(s, s.backoff)}
  end

  defp failed(s, reason) do
    backoff = s.backoff |> Kernel.*(2) |> max(@min_backoff) |> min(@max_backoff)
    flag(s, true, System.monotonic_time(:millisecond) + backoff)
    %{s | backoff: backoff, last_error: tag(reason)}
  end

  defp flag(s, needs_pull, retry_at), do: :ets.insert(s.table, [{:needs_pull, needs_pull}, {:retry_at, retry_at}])
  defp needs_pull?(s), do: :ets.lookup(s.table, :needs_pull) == [{:needs_pull, true}]

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

  defp pull_all(s, overlap? \\ true) do
    cursor = Store.pull_cursor(s.store)

    case normalize(s.pull_fun.(cursor, @page, overlap: overlap?)) do
      {:ok, rows} -> apply_page(s, rows, cursor)
      {:error, reason} -> {:error, reason, s}
    end
  end

  defp apply_page(s, rows, cursor) do
    {valid, invalid} = Enum.split_with(rows, &(Change.validate(&1) == :ok))
    max_seq = rows |> Enum.map(& &1.seq) |> Enum.max(fn -> cursor end)
    page_rows = Enum.count(rows, &(&1.seq > cursor))
    s = %{s | skipped_invalid: s.skipped_invalid + length(invalid)}

    case Store.append_remote(s.store, valid, cursor: max_seq) do
      {:ok, fresh} ->
        if fresh != [], do: s.on_remote_applied.(fresh)
        next_page(s, page_rows)

      {:error, reason} ->
        {:error, reason, s}
    end
  end

  # A full page means more may follow; the overlap rows are fetched once per pull, not per page.
  defp next_page(s, @page), do: pull_all(s, false)

  defp next_page(s, _count), do: {:ok, s}

  defp normalize(:disabled), do: {:error, :disabled}
  defp normalize(other), do: other

  defp bounded_pull(s, timeout) do
    task = Task.async(fn -> pull_all(s) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, s2}} ->
        flag(s2, false, System.monotonic_time(:millisecond))
        {:ok, %{s2 | last_error: nil}}

      {:ok, {:error, reason, s2}} ->
        {{:error, reason}, failed(s2, reason)}

      _ ->
        {{:error, :timeout}, failed(s, :timeout)}
    end
  end

  defp schedule(s, delay) do
    if s.timer, do: Process.cancel_timer(s.timer)
    %{s | timer: Process.send_after(self(), :sync, delay)}
  end
end
