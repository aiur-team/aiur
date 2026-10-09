defmodule Aiur.StartTrigger.ProgressStore do
  @moduledoc "Monotonic per-PR facts. Issue freshness is checked separately by StartTrigger."
  use GenServer
  require Logger
  alias Aiur.StartTrigger

  @table :aiur_start_trigger_progress
  @empty_retention_ms 86_400_000
  @type row :: %{pr_number: integer() | nil, stage: StartTrigger.trigger() | nil, closed_unmerged?: boolean(), observed_at_ms: integer(), source: atom(), head_sha: String.t() | nil}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec lookup(String.t()) :: row() | nil
  def lookup(id) do
    case :ets.lookup(@table, id) do
      [{^id, %{stage: nil, observed_at_ms: at} = row}] -> if System.system_time(:millisecond) - at <= @empty_retention_ms, do: row
      [{^id, row}] -> row
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec record(String.t(), map()) :: :ok
  def record(id, attrs), do: GenServer.cast(__MODULE__, {:record, id, attrs})

  @spec watch([String.t()], :pr_approved, keyword()) :: :ok
  def watch(ids, :pr_approved, opts \\ []), do: GenServer.cast(__MODULE__, {:watch, ids, Keyword.get(opts, :observation_max_age_ms, 60_000)})

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    clock = Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end)
    seed = Keyword.get(opts, :seed, fn -> %{passed_heads: %{}} end).()

    for {id, sha} <- seed.passed_heads do
      put(id, %{pr_number: nil, stage: :pr_ci_green, head_sha: sha, source: :boot}, clock.())
      if identity = Keyword.get(opts, :identity, fn _ -> nil end).(id), do: put(id, identity, clock.())
    end

    {:ok, %{clock: clock, reader: Keyword.get(opts, :reader), watches: %{}, timer: nil}}
  end

  @impl true
  def handle_cast({:record, id, attrs}, state) do
    put(id, attrs, state.clock.())
    {:noreply, state}
  end

  def handle_cast({:watch, ids, age}, state) do
    now = state.clock.()
    interval = max(div(age, 2), 1)

    watches =
      Enum.reduce(ids, state.watches, fn id, watches ->
        previous = Map.get(watches, id, %{read_at: nil, error: nil})
        Map.put(watches, id, Map.merge(previous, %{expires_at: now + 2 * interval, interval: interval}))
      end)

    send(self(), :refresh)
    {:noreply, %{state | watches: watches}}
  end

  @impl true
  def handle_info(:refresh, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    now = state.clock.()
    watches = state.watches |> Enum.reject(fn {_id, watch} -> watch.expires_at <= now end) |> Map.new()
    watches = Map.new(watches, fn {id, watch} -> {id, refresh(id, watch, state, now)} end)
    interval = watches |> Map.values() |> Enum.map(& &1.interval) |> Enum.min(fn -> 30_000 end)
    timer = if map_size(watches) > 0, do: Process.send_after(self(), :refresh, interval)
    {:noreply, %{state | watches: watches, timer: timer}}
  end

  defp refresh(id, watch, state, now) do
    if state.reader && (is_nil(watch.read_at) or now - watch.read_at >= watch.interval) do
      error =
        case read(state.reader, id, lookup(id)) do
          {:ok, attrs} when is_map(attrs) ->
            put(id, attrs, now)
            nil

          {:ok, nil} ->
            nil

          {:error, reason} ->
            log_read_error(id, watch.error, reason)
            reason
        end

      %{watch | read_at: now, error: error}
    else
      watch
    end
  end

  defp log_read_error(_id, error, error), do: :ok
  defp log_read_error(id, _previous, reason), do: Logger.warning("Blocker approval read failed ticket=#{id} reason=#{inspect(reason)}")

  defp read(reader, id, row) do
    reader.(id, row)
  rescue
    error -> {:error, {:reader_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp put(id, attrs, now) do
    incoming = Map.merge(%{pr_number: nil, stage: nil, closed_unmerged?: false, observed_at_ms: now, source: :unknown, head_sha: nil}, attrs)
    incoming = if incoming.closed_unmerged?, do: %{incoming | stage: nil}, else: incoming
    previous = lookup(id)
    row = if same_pr?(previous, incoming), do: advance(previous, incoming), else: incoming
    :ets.insert(@table, {id, row})
  end

  defp same_pr?(nil, _incoming), do: false
  defp same_pr?(%{pr_number: nil, head_sha: sha}, %{head_sha: sha}) when is_binary(sha), do: true
  defp same_pr?(%{pr_number: number}, %{pr_number: number}) when is_integer(number), do: true
  defp same_pr?(_previous, _incoming), do: false

  defp advance(previous, %{closed_unmerged?: true} = incoming), do: %{incoming | stage: nil, head_sha: incoming.head_sha || previous.head_sha}
  defp advance(%{closed_unmerged?: true} = previous, %{source: source}) when source in [:ci, :review], do: previous

  defp advance(previous, incoming) do
    stage = if StartTrigger.satisfies?(previous.stage, incoming.stage || :pr_opened), do: previous.stage, else: incoming.stage
    %{incoming | stage: stage, head_sha: incoming.head_sha || previous.head_sha}
  end
end
