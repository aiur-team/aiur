defmodule Aiur.CurrentRunMembership.Reconciler do
  @moduledoc false

  use GenServer

  require Logger

  alias Aiur.{AgentPubSub, TrackerIdentity}
  alias Aiur.CurrentRunMembership
  alias Aiur.Orchestrator.{DispatchPolicy, StatusReport}

  @waiting_reasons [
    :waiting_for_human,
    :waiting_for_supervisor,
    :waiting_for_dependency,
    :waiting_for_ci,
    :waiting_for_review,
    :awaiting_dispatch,
    :backing_off,
    :unresponsive
  ]
  @lifecycle_values [:queued, :retrying, :allocated, :running, :paused, :waiting, :replaced, :completed, :cancelled]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec reconcile_snapshot(map(), (TrackerIdentity.t(), atom() -> term()), MapSet.t()) :: [term()]
  def reconcile_snapshot(snapshot, observe_fun, terminal_states)
      when is_map(snapshot) and is_function(observe_fun, 2) and is_struct(terminal_states, MapSet) do
    snapshot
    |> observation_rows()
    |> Enum.flat_map(&observe_row(&1, observe_fun, terminal_states))
  end

  @impl true
  def init(opts) do
    state = %{
      snapshot_fun: Keyword.get(opts, :snapshot_fun, &StatusReport.snapshot_api/0),
      observe_fun: Keyword.get(opts, :observe_fun, &CurrentRunMembership.observe/2),
      terminal_states_fun: Keyword.get(opts, :terminal_states_fun, &DispatchPolicy.terminal_state_set/0),
      subscribe_fun: Keyword.get(opts, :subscribe_fun, &AgentPubSub.subscribe_running/0),
      membership_subscribe_fun: Keyword.get(opts, :membership_subscribe_fun, &CurrentRunMembership.subscribe/0),
      reconciliation_fun: Keyword.get(opts, :reconciliation_fun, &CurrentRunMembership.mark_reconciled/1),
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
    {:noreply, %{state | reconcile_pending?: false}}
  end

  def handle_info({:running_changed, _summaries}, state), do: {:noreply, schedule_reconciliation(state)}

  def handle_info({:current_run_membership_health_changed, _snapshot}, state),
    do: {:noreply, schedule_reconciliation(state)}

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_reconciliation(%{reconcile_pending?: true} = state), do: state

  defp schedule_reconciliation(state) do
    send(self(), :reconcile)
    %{state | reconcile_pending?: true}
  end

  defp reconcile(state) do
    case {safe_snapshot(state.snapshot_fun), safe_terminal_states(state.terminal_states_fun)} do
      {snapshot, terminal_states} when is_map(snapshot) and is_struct(terminal_states, MapSet) ->
        snapshot
        |> reconcile_snapshot(state.observe_fun, terminal_states)
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

  defp log_reconcile_failure(details) do
    Logger.warning("aiur_current_run_membership phase=reconcile_failed #{details}")
  end

  defp reconciliation_status(results) do
    if Enum.all?(results, &match?({:ok, _}, &1)), do: :fresh, else: :unavailable
  end

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

  defp log_reconciliation_mark_failure(details) do
    Logger.warning("aiur_current_run_membership phase=reconciliation_mark_failed #{details}")
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

  defp observation_rows(snapshot) do
    rows_by_kind = [
      running: Map.get(snapshot, :running, []),
      retrying: Map.get(snapshot, :retrying, []),
      idle: Map.get(snapshot, :idle, [])
    ]

    for {kind, rows} <- rows_by_kind,
        row <- rows,
        is_map(row) do
      {kind, row}
    end
  end

  defp tracker_identity(row), do: Map.get(row, :tracker_identity) || Map.get(row, "tracker_identity")

  defp observe_row({kind, row}, observe_fun, terminal_states) do
    case tracker_identity(row) do
      %TrackerIdentity{} = identity -> observe_joinable(identity, kind, row, observe_fun, terminal_states)
      _ -> []
    end
  end

  defp observe_joinable(identity, kind, row, observe_fun, terminal_states) do
    if TrackerIdentity.joinable?(identity) do
      [observe_fun.(identity, lifecycle(kind, row, terminal_states))]
    else
      []
    end
  end

  defp lifecycle(kind, row, terminal_states) do
    explicit_lifecycle(row) ||
      terminal_lifecycle_for(row, terminal_states) ||
      replaced_lifecycle(row) ||
      paused_lifecycle(row) ||
      waiting_lifecycle(row) ||
      allocated_lifecycle(row) ||
      lifecycle_for_row_kind(kind)
  end

  defp explicit_lifecycle(row) do
    lifecycle = row_value(row, :lifecycle)
    if lifecycle in @lifecycle_values, do: lifecycle
  end

  defp terminal_lifecycle_for(row, terminal_states) do
    state = row_value(row, :state)
    if DispatchPolicy.terminal_issue_state?(state, terminal_states), do: terminal_lifecycle(state)
  end

  defp replaced_lifecycle(row) do
    if normalize_state(row_value(row, :state)) == "replaced" or row_value(row, :work_state) == :replaced do
      :replaced
    end
  end

  defp paused_lifecycle(row) do
    if tracker_paused?(row) or row_value(row, :work_state) in [:paused, :sleeping], do: :paused
  end

  defp waiting_lifecycle(row) do
    if row_value(row, :waiting_reason) in @waiting_reasons, do: :waiting
  end

  defp allocated_lifecycle(row) do
    if row_value(row, :work_state) == :allocated, do: :allocated
  end

  defp lifecycle_for_row_kind(:retrying), do: :retrying
  defp lifecycle_for_row_kind(:running), do: :running
  defp lifecycle_for_row_kind(:idle), do: :queued

  defp terminal_lifecycle(state) do
    if normalize_state(state) in ["cancelled", "canceled"], do: :cancelled, else: :completed
  end

  defp tracker_paused?(row) do
    Map.get(row, :tracker_paused) == true or Map.get(row, "tracker_paused") == true
  end

  defp row_value(row, key), do: Map.get(row, key) || Map.get(row, Atom.to_string(key))

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
end
