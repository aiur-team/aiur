defmodule Aiur.CurrentRunMembership.Reconciler do
  @moduledoc false

  use GenServer

  require Logger

  alias Aiur.AgentPubSub
  alias Aiur.CurrentRunMembership
  alias Aiur.CurrentRunMembership.Reconciler.Snapshot
  alias Aiur.Orchestrator, as: Orchestrator
  alias Aiur.Orchestrator.{DispatchPolicy, SnapshotStore}
  alias Aiur.TrackerIdentity

  @default_reconcile_interval_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec reconcile_snapshot(map(), (TrackerIdentity.t(), atom() -> term()), MapSet.t()) :: [term()]
  defdelegate reconcile_snapshot(snapshot, observe_fun, terminal_states), to: Snapshot, as: :reconcile

  @doc false
  @spec lifecycle_for_status_row(atom(), map()) :: atom()
  def lifecycle_for_status_row(bucket, row) do
    Snapshot.lifecycle_for_row(bucket, row, DispatchPolicy.terminal_state_set())
  end

  @impl true
  def init(opts) do
    state = %{
      snapshot_fun: Keyword.get(opts, :snapshot_fun, &current_snapshot/0),
      observe_fun: Keyword.get(opts, :observe_fun, &CurrentRunMembership.observe/2),
      terminal_states_fun: Keyword.get(opts, :terminal_states_fun, &DispatchPolicy.terminal_state_set/0),
      subscribe_fun: Keyword.get(opts, :subscribe_fun, &AgentPubSub.subscribe_running/0),
      membership_subscribe_fun: Keyword.get(opts, :membership_subscribe_fun, &CurrentRunMembership.subscribe/0),
      reconciliation_fun: Keyword.get(opts, :reconciliation_fun, &CurrentRunMembership.mark_reconciled/1),
      reconcile_interval_ms: Keyword.get(opts, :reconcile_interval_ms, @default_reconcile_interval_ms),
      reconcile_timer_ref: nil,
      reconcile_pending?: true
    }

    _ = state.subscribe_fun.()
    _ = state.membership_subscribe_fun.()
    send(self(), :reconcile)
    {:ok, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile(state)

    state =
      state
      |> Map.put(:reconcile_pending?, false)
      |> schedule_reconciliation_tick()

    {:noreply, state}
  end

  def handle_info({:running_changed, _summaries}, state), do: {:noreply, schedule_reconciliation(state)}
  def handle_info({:current_run_membership_health_changed, _snapshot}, state), do: {:noreply, schedule_reconciliation(state)}

  def handle_info(:reconcile_tick, state) do
    state = %{state | reconcile_timer_ref: nil}
    {:noreply, schedule_reconciliation(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_reconciliation(%{reconcile_pending?: true} = state), do: state

  defp schedule_reconciliation(state) do
    send(self(), :reconcile)
    %{state | reconcile_pending?: true}
  end

  defp schedule_reconciliation_tick(%{reconcile_timer_ref: reference} = state)
       when is_reference(reference),
       do: state

  defp schedule_reconciliation_tick(%{reconcile_interval_ms: :infinity} = state), do: state

  defp schedule_reconciliation_tick(%{reconcile_interval_ms: interval_ms} = state)
       when is_integer(interval_ms) and interval_ms > 0 do
    %{state | reconcile_timer_ref: Process.send_after(self(), :reconcile_tick, interval_ms)}
  end

  defp schedule_reconciliation_tick(state), do: state

  defp current_snapshot do
    case SnapshotStore.read(Orchestrator, 15_000) do
      {:current, snapshot, _metadata} -> snapshot
      _result -> :unavailable
    end
  end

  defp reconcile(state) do
    case {safe_snapshot(state.snapshot_fun), safe_terminal_states(state.terminal_states_fun)} do
      {snapshot, terminal_states} when is_map(snapshot) and is_struct(terminal_states, MapSet) ->
        snapshot
        |> Snapshot.reconcile(state.observe_fun, terminal_states)
        |> reconciliation_status()
        |> then(&mark_reconciled(state, &1))

      _ ->
        mark_reconciled(state, :unavailable)
    end
  rescue
    error ->
      mark_reconciled(state, :unavailable)
      log_reconcile_failure("error=#{Exception.message(error)}")
  catch
    kind, reason ->
      mark_reconciled(state, :unavailable)
      log_reconcile_failure("reason=#{inspect({kind, reason})}")
  end

  defp reconciliation_status(results), do: if(Enum.all?(results, &match?({:ok, _}, &1)), do: :fresh, else: :unavailable)

  defp mark_reconciled(state, status) do
    case state.reconciliation_fun.(status) do
      :ok -> :ok
      {:error, reason} -> log_reconciliation_mark_failure("reason=#{inspect(reason)}")
      _ -> :ok
    end
  rescue
    error -> log_reconciliation_mark_failure("error=#{Exception.message(error)}")
  catch
    kind, reason -> log_reconciliation_mark_failure("reason=#{inspect({kind, reason})}")
  end

  defp safe_snapshot(fun) do
    fun.()
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  defp safe_terminal_states(fun) do
    fun.()
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  defp log_reconcile_failure(details), do: Logger.warning("aiur_current_run_membership phase=reconcile_failed #{details}")
  defp log_reconciliation_mark_failure(details), do: Logger.warning("aiur_current_run_membership phase=reconciliation_mark_failed #{details}")
end
