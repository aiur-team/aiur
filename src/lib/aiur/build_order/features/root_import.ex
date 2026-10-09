defmodule Aiur.BuildOrder.Features.RootImport do
  @moduledoc "Imports Build Order roots from local History into the feature registry."
  use GenServer
  alias Aiur.BuildOrder.{Features, History}
  alias Aiur.BuildOrder.Features.{RootImportMapping, RootImportPlan, RootImportWrites}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  @spec slug(pos_integer()) :: String.t()
  defdelegate slug(number), to: RootImportMapping
  @spec clean(term()) :: String.t()
  defdelegate clean(title), to: RootImportMapping
  @spec plan(map(), map(), map()) :: map()
  defdelegate plan(history, features, journals), to: RootImportPlan
  @spec status(GenServer.server()) :: term()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    state = %{
      enabled?: Keyword.get(opts, :enabled?, true),
      status: :disabled,
      timer: nil,
      history: Keyword.get(opts, :history, &History.snapshot/0),
      features: Keyword.get(opts, :features, fn op, args -> apply(Features, op, args) end),
      debounce_ms: Keyword.get(opts, :debounce_ms, 2_000),
      retry_ms: Keyword.get(opts, :retry_ms, 60_000)
    }

    if state.enabled? do
      case Keyword.get(opts, :subscribe, &History.subscribe/0).() do
        :ok -> {:ok, state, {:continue, :run}}
        {:error, reason} -> {:stop, {:subscription_failed, reason}}
      end
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:run, state), do: {:noreply, run(state)}
  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}
  @impl true
  def handle_info(:run, %{enabled?: true} = state), do: {:noreply, run(cancel(state))}
  def handle_info({:build_order_history_changed, _}, %{enabled?: true} = state), do: {:noreply, schedule(state, state.debounce_ms)}
  def handle_info(_message, state), do: {:noreply, state}

  # ponytail: full snapshots suffice for ~10k rows; use changed numbers after measured cost.
  defp run(state) do
    case state.history.() do
      {:error, health} -> %{state | status: {:unavailable, health.failure}}
      {:ok, %{health: %{failure: :backfill_pending}}} -> %{state | status: {:unavailable, :backfill_pending}}
      {:ok, history} -> registry(state, history)
    end
  end

  defp registry(state, history) do
    with {:ok, features} <- state.features.(:snapshot, [[]]),
         {:ok, journals} <- journals(state, features) do
      plan = plan(history, features, journals)

      case RootImportWrites.apply(plan, state.features) do
        :ok -> %{state | status: {:ok, summary(plan, history)}}
        {:error, reason} -> schedule(%{state | status: {:partial, reason}}, state.retry_ms)
      end
    else
      {:error, health} -> schedule(%{state | status: {:unavailable, health.failure}}, state.retry_ms)
    end
  end

  defp journals(state, features) do
    features.features
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, "bo-"))
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn slug, {:ok, journals} ->
      case state.features.(:journal, [slug, []]) do
        {:ok, events} -> {:cont, {:ok, Map.put(journals, slug, events)}}
        error -> {:halt, error}
      end
    end)
  end

  defp summary(plan, history) do
    roots = Enum.count(history.rows, fn {_, row} -> is_list(row.labels) and Aiur.BuildOrder.CatalogStore.root_label() in row.labels end)

    %{
      at: DateTime.utc_now(),
      roots: roots,
      added: count(plan.adds),
      removed: count(plan.removes),
      moved: count(plan.moves),
      conflicts: plan.conflicts,
      deferred: plan.deferred,
      skipped_cross_repo: plan.skipped_cross_repo,
      skipped_lanes: plan.skipped_lanes,
      health: history.health
    }
  end

  defp count(ops), do: Enum.reduce(ops, 0, fn op, n -> n + length(elem(op, 1)) end)

  defp cancel(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  defp schedule(state, ms) do
    state = cancel(state)
    %{state | timer: Process.send_after(self(), :run, ms)}
  end
end
