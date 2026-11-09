defmodule Aiur.Commands.Routing do
  @moduledoc "Routes open Commands and durably escalates unanswered Executor work."
  use GenServer
  require Logger

  alias Aiur.Commands.Routing.{Policy, Sweep}
  alias Aiur.{Config, DecisionPubSub, DecisionStore, Signal}
  alias Aiur.Executor.Roster

  @ceiling_ms 30_000
  @waiting_topic "system.commands.executor_only_waiting"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    :ok = DecisionPubSub.subscribe()

    state = %{
      store: Keyword.get(opts, :store, DecisionStore),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      roster_fun: Keyword.get(opts, :roster_fun, &Roster.build/1),
      config: Keyword.get(opts, :config, &Config.decision_escalation/0),
      alert_fun: Keyword.get(opts, :alert_fun, &Signal.agent_alert/3),
      waiting_alerted: MapSet.new(),
      timer_ref: nil,
      next_due_at: nil
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state), do: {:noreply, sweep(state)}

  @impl true
  def handle_info(:tick, state), do: {:noreply, sweep(state)}

  def handle_info({:decision_changed, id, _version}, state) do
    {:noreply, sweep(state, id)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A synchronous barrier for deterministic sweeps without sleeping on timers.
  @impl true
  def handle_call(:sweep, _from, state) do
    next = sweep(state)
    {:reply, :ok, next}
  end

  defp sweep(state, id \\ nil) do
    now = state.clock.()

    {due, state} =
      case read_config(state.config) do
        {:ok, %{enabled: true} = config} ->
          run_sweep(state, id, now, config)

        {:ok, %{enabled: false}} ->
          {nil, state}

        {:error, reason} ->
          Logger.warning("aiur_command_routing config_unavailable reason=#{inspect(reason)}")
          {nil, state}
      end

    # A change can introduce an earlier deadline; preserve the earlier full-sweep timer.
    due = if id, do: earliest(due, state.next_due_at), else: due
    arm_timer(state, id, due, now)
  end

  defp arm_timer(state, id, due, now) do
    delay = if due, do: DateTime.diff(due, now, :millisecond) |> max(1) |> min(@ceiling_ms), else: @ceiling_ms
    remaining = state.timer_ref && Process.read_timer(state.timer_ref)

    if id && is_integer(remaining) && remaining <= delay do
      %{state | next_due_at: due}
    else
      if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
      %{state | next_due_at: due, timer_ref: Process.send_after(self(), :tick, delay)}
    end
  end

  defp read_config(config) do
    {:ok, if(is_function(config, 0), do: config.(), else: config)}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp run_sweep(state, id, now, config) do
    decisions =
      if id do
        case DecisionStore.get(id, state.store) do
          {:ok, decision} -> [decision]
          {:error, :not_found} -> []
        end
      else
        DecisionStore.list(state.store)
      end

    liveness = roster(state, now)
    {due, errors} = Sweep.run(decisions, liveness, now, config, state.store)
    if errors != [], do: Logger.warning("aiur_command_routing write_failed errors=#{inspect(errors)}")
    {due, alert_waiting(state, decisions, liveness, id)}
  rescue
    error ->
      Logger.warning("aiur_command_routing sweep_failed reason=#{Exception.message(error)}")
      {nil, state}
  catch
    :exit, reason ->
      Logger.warning("aiur_command_routing store_unavailable reason=#{inspect(reason)}")
      {nil, state}
  end

  # An Executor-only Command never falls back to the creator, so the operator is
  # told once per outage that it waits; a full sweep with a live Executor re-arms.
  defp alert_waiting(state, _decisions, :live, nil), do: %{state | waiting_alerted: MapSet.new()}
  defp alert_waiting(state, _decisions, :live, _id), do: state

  defp alert_waiting(state, decisions, liveness, _id) do
    decisions
    |> Enum.filter(&(Policy.executor_audience?(&1) and &1.decision_status in [:open, :deferred] and is_nil(&1.answer)))
    |> Enum.reject(&MapSet.member?(state.waiting_alerted, &1.decision_id))
    |> Enum.reduce(state, fn decision, acc ->
      message = "Executor-only Command #{decision.decision_id} on ##{decision.ticket.identifier} is waiting: no live Executor (#{liveness})."
      acc.alert_fun.(@waiting_topic, message, needs_attention: true, severity: "warning", central: true)
      %{acc | waiting_alerted: MapSet.put(acc.waiting_alerted, decision.decision_id)}
    end)
  end

  defp roster(state, now) do
    state.roster_fun.(record?: false, now: now) |> Policy.liveness()
  rescue
    error ->
      Logger.warning("aiur_command_routing roster_failed reason=#{Exception.message(error)}")
      :stalled
  catch
    kind, reason ->
      Logger.warning("aiur_command_routing roster_failed reason=#{inspect({kind, reason})}")
      :stalled
  end

  defp earliest(nil, at), do: at
  defp earliest(at, nil), do: at
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
end
