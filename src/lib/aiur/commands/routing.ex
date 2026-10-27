defmodule Aiur.Commands.Routing do
  @moduledoc "Routes open Commands and durably escalates unanswered Executor work."
  use GenServer
  require Logger

  alias Aiur.Commands.Routing.{Policy, Sweep}
  alias Aiur.{Config, DecisionPubSub, DecisionStore}
  alias Aiur.Executor.Roster

  @ceiling_ms 30_000

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

    due =
      case read_config(state.config) do
        {:ok, %{enabled: true} = config} ->
          run_sweep(state, id, now, config)

        {:ok, %{enabled: false}} ->
          nil

        {:error, reason} ->
          Logger.warning("aiur_command_routing config_unavailable reason=#{inspect(reason)}")
          nil
      end

    # A change can introduce an earlier deadline; preserve the earlier full-sweep timer.
    due = if id, do: earliest(due, state.next_due_at), else: due
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

    {due, errors} = Sweep.run(decisions, roster(state, now), now, config, state.store)
    if errors != [], do: Logger.warning("aiur_command_routing write_failed errors=#{inspect(errors)}")
    due
  rescue
    error ->
      Logger.warning("aiur_command_routing sweep_failed reason=#{Exception.message(error)}")
      nil
  catch
    :exit, reason ->
      Logger.warning("aiur_command_routing store_unavailable reason=#{inspect(reason)}")
      nil
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
