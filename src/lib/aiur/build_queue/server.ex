defmodule Aiur.BuildQueue.Server do
  @moduledoc "Owns dispatch hints and coalesces tracker signals into queue plans and executes paced label writes."
  use GenServer
  require Logger

  alias Aiur.BuildQueue.{ClaimProbe, Hints, ListCommands, Reconcile, Settings, Store, Writer}
  alias Aiur.Events.Exchange

  @patterns ["ticket.*.pr.merged", "ticket.*.issue.label.added.agent.*", "ticket.*.agent.attention.#", "ticket.*.dependency.merged_blocker_reconciled"]
  @debounce_ms 2_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    {:ok, settings} = Keyword.get_lazy(opts, :settings, &Aiur.Config.settings/0)

    state = %{
      settings: settings,
      writer: Writer.new(),
      write_results: [],
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      tracker: Keyword.get(opts, :tracker, Aiur.Tracker),
      store: Keyword.get(opts, :store, Store),
      claim_probe: Keyword.get(opts, :claim_probe, ClaimProbe),
      clock: Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end),
      schedule: Keyword.get(opts, :schedule, &Process.send_after/3),
      exchange: Keyword.get(opts, :exchange, Exchange),
      exchange_pid: nil,
      pending: nil,
      status: :disabled,
      document: nil,
      projections: [],
      actions: [],
      holds: MapSet.new(),
      reconciles: 0
    }

    {:ok, initialize(state)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}
  def handle_call(:show, _from, state), do: {:reply, {:ok, Map.take(state, [:status, :projections, :actions, :reconciles])}, state}

  def handle_call({:write, action, id}, _from, %{status: status} = state) when action in [:mark, :unmark] and status == :running do
    state = write(state, [{action, id}], Reconcile.observations(state))
    {:reply, state.write_results |> List.last() |> elem(2), state}
  end

  def handle_call({:write, _, _}, _from, state), do: {:reply, {:error, state.status}, state}

  def handle_call({:mutate, command}, _from, %{status: :running} = state) do
    case ListCommands.prepare(state, command) do
      {:ok, document, actions, observations} ->
        case state.store.save(document) do
          :ok ->
            state = write(%{state | document: document}, actions, observations)
            failures = Enum.reject(state.write_results, &(elem(&1, 2) == :ok))
            reply = if failures == [], do: :ok, else: {:error, {:marker_write_failed, failures}}
            {:reply, reply, request(state)}

          {:error, _} ->
            {:reply, {:error, :store_unavailable}, %{state | status: :store_unavailable}}
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:mutate, _}, _from, state), do: {:reply, {:error, state.status}, state}
  def handle_call(:reconcile_now, _from, state), do: {:reply, :ok, request(state)}

  @impl true
  def handle_info({:open_issues_recorded, _}, state), do: {:noreply, request(state)}
  def handle_info({:event, _}, state), do: {:noreply, request(state)}

  def handle_info(:tick, %{status: status} = state) when status in [:running, :writes_paused] do
    schedule_tick(state)
    {:noreply, state |> subscribe() |> request()}
  end

  def handle_info({:reconcile, token}, %{pending: token, status: status} = state) when status in [:running, :writes_paused] do
    {:noreply, reconcile(%{state | pending: nil})}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{exchange_pid: pid} = state), do: {:noreply, %{state | exchange_pid: nil}}
  def handle_info(_message, state), do: {:noreply, state}

  defp initialize(%{settings: %{build_queue: %{enabled: false}}} = state), do: state

  defp initialize(state) do
    if state.tracker.open_issue_labels(1) == {:error, :unsupported} do
      %{state | status: :unsupported_tracker}
    else
      :ets.new(Hints.table_name(), [:named_table, :set, :protected, read_concurrency: true])
      recover(state)
    end
  end

  defp recover(state) do
    # Safe ETF decoding needs the producer atoms present before store recovery.
    Enum.each([Aiur.BuildQueue.Planner, Aiur.BuildQueue.PlannerPolicy, Aiur.BuildQueue.Readiness, Aiur.BuildQueue.Attention], &Code.ensure_loaded!/1)

    case state.store.load() do
      {:ok, document} ->
        Phoenix.PubSub.subscribe(Aiur.PubSub, "tracker:open_issues")
        state = %{state | status: :running, document: document}
        schedule_tick(state)
        state |> subscribe() |> request()

      {:error, reason} ->
        Logger.error("Build queue store unavailable: #{inspect(reason)}")
        %{state | status: :store_unavailable}
    end
  end

  defp schedule_tick(state), do: state.schedule.(self(), :tick, state.settings.build_queue.reconcile_interval_seconds * 1000)

  defp request(%{status: status, pending: nil} = state) when status in [:running, :writes_paused] do
    token = make_ref()
    state.schedule.(self(), {:reconcile, token}, @debounce_ms)
    %{state | pending: token}
  end

  defp request(state), do: state

  defp reconcile(state) do
    pending = ListCommands.pending(state.document)
    state = if pending == [], do: state, else: write(state, pending, Reconcile.observations(state))
    if state.status == :store_unavailable, do: state, else: reconcile_plan(state)
  end

  defp reconcile_plan(state) do
    {projections, actions, observations} = Reconcile.plan(state)
    state = write(state, actions, observations)

    holds =
      Enum.reduce(actions, state.holds, fn
        {:begin_withdraw, id}, holds -> MapSet.put(holds, id)
        {:hold_release, id}, holds -> MapSet.delete(holds, id)
        _, holds -> holds
      end)

    retained = for p <- projections, p.state not in [:removed, :completed, :cancelled], do: p.issue_id
    holds = MapSet.intersection(holds, MapSet.new(retained))
    Reconcile.write_hints(projections, holds, state.document)
    Phoenix.PubSub.broadcast(Aiur.PubSub, "build_queue:changed", {:build_queue_changed, state.status})
    %{state | projections: projections, actions: state.actions, holds: holds, reconciles: state.reconciles + 1}
  end

  defp write(state, actions, observations) do
    prefix = state.settings.tracker.github.label_prefix

    context =
      Map.merge(state, %{
        observations: observations,
        marker: "#{prefix}:queued",
        todo: "#{prefix}:todo",
        max_writes: state.settings.build_queue.max_writes_per_minute,
        observation_max_age_ms: Settings.observation_max_age_ms(state.settings)
      })

    result = Writer.run(context, actions, state.writer)
    status = if result.status == :paced, do: :running, else: result.status
    %{state | document: result.document, writer: result.writer, write_results: result.write_results, status: status, actions: actions ++ result.write_attentions}
  end

  defp subscribe(%{exchange_pid: pid} = state) when is_pid(pid), do: state

  defp subscribe(state) do
    case GenServer.whereis(state.exchange) do
      nil -> state
      pid -> bind(state, pid)
    end
  end

  defp bind(state, pid) do
    Enum.each(@patterns, &Exchange.subscribe(&1, state.exchange))
    Process.monitor(pid)
    %{state | exchange_pid: pid}
  catch
    :exit, reason ->
      Logger.warning("Build queue Exchange subscription unavailable: #{inspect(reason)}")
      state
  end
end
