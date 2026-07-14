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
    |> Enum.flat_map(fn {kind, row} ->
      case tracker_identity(row) do
        identity when is_struct(identity, TrackerIdentity) ->
          if TrackerIdentity.joinable?(identity), do: [observe_fun.(identity, lifecycle(kind, row, terminal_states))], else: []

        _ ->
          []
      end
    end)
  end

  @impl true
  def init(opts) do
    state = %{
      snapshot_fun: Keyword.get(opts, :snapshot_fun, &StatusReport.snapshot_api/0),
      observe_fun: Keyword.get(opts, :observe_fun, &CurrentRunMembership.observe/2),
      terminal_states_fun: Keyword.get(opts, :terminal_states_fun, &DispatchPolicy.terminal_state_set/0),
      subscribe_fun: Keyword.get(opts, :subscribe_fun, &AgentPubSub.subscribe_running/0),
      reconcile_pending?: true
    }

    _ = state.subscribe_fun.()
    send(self(), :reconcile)
    {:ok, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile(state)
    {:noreply, %{state | reconcile_pending?: false}}
  end

  def handle_info({:running_changed, _summaries}, state), do: {:noreply, schedule_reconciliation(state)}
  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_reconciliation(%{reconcile_pending?: true} = state), do: state

  defp schedule_reconciliation(state) do
    send(self(), :reconcile)
    %{state | reconcile_pending?: true}
  end

  defp reconcile(state) do
    with snapshot when is_map(snapshot) <- safe_snapshot(state.snapshot_fun),
         terminal_states when is_struct(terminal_states, MapSet) <- safe_terminal_states(state.terminal_states_fun) do
      reconcile_snapshot(snapshot, state.observe_fun, terminal_states)
    else
      _ -> :ok
    end
  rescue
    error -> Logger.warning("aiur_current_run_membership phase=reconcile_failed error=#{Exception.message(error)}")
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
    _ -> MapSet.new()
  catch
    _, _ -> MapSet.new()
  end

  defp observation_rows(snapshot) do
    for {kind, rows} <- [running: Map.get(snapshot, :running, []), retrying: Map.get(snapshot, :retrying, []), idle: Map.get(snapshot, :idle, [])],
        row <- rows,
        is_map(row) do
      {kind, row}
    end
  end

  defp tracker_identity(row), do: Map.get(row, :tracker_identity) || Map.get(row, "tracker_identity")

  defp lifecycle(kind, row, terminal_states) do
    explicit_lifecycle = Map.get(row, :lifecycle) || Map.get(row, "lifecycle")
    state = Map.get(row, :state) || Map.get(row, "state")
    work_state = Map.get(row, :work_state) || Map.get(row, "work_state")
    waiting_reason = Map.get(row, :waiting_reason) || Map.get(row, "waiting_reason")

    cond do
      explicit_lifecycle in @lifecycle_values -> explicit_lifecycle
      DispatchPolicy.terminal_issue_state?(state, terminal_states) -> terminal_lifecycle(state)
      normalize_state(state) == "replaced" or work_state == :replaced -> :replaced
      Map.get(row, :tracker_paused) == true or Map.get(row, "tracker_paused") == true or work_state in [:paused, :sleeping] -> :paused
      waiting_reason in @waiting_reasons -> :waiting
      work_state == :allocated -> :allocated
      true -> lifecycle_for_row_kind(kind)
    end
  end

  defp lifecycle_for_row_kind(:retrying), do: :retrying
  defp lifecycle_for_row_kind(:running), do: :running
  defp lifecycle_for_row_kind(:idle), do: :queued

  defp terminal_lifecycle(state) do
    if normalize_state(state) in ["cancelled", "canceled"], do: :cancelled, else: :completed
  end

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
end
