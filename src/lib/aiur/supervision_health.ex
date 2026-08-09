defmodule Aiur.SupervisionHealth do
  @moduledoc """
  Liveness reporting for the application's fixed supervision contract.

  The expected children are supplied from `Aiur.Application.child_specs/1`, so
  the monitor cannot silently drift from the supervisor it observes. Dynamic
  supervisors intentionally contribute their own supervisor process, not each
  runtime child: dynamic children have no fixed expected set.
  """

  use GenServer

  alias Aiur.Alerts
  alias Aiur.SupervisionHealth.Formatter
  alias Aiur.SupervisionHealth.Tree
  require Logger

  @default_check_interval 15_000
  @restart_grace_ms 50

  @type snapshot :: %{
          expected: non_neg_integer(),
          healthy: non_neg_integer(),
          missing: [%{id: term(), reason: term() | nil}]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec status(GenServer.server()) :: {:ok, snapshot()} | {:error, :unavailable}
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec check(Supervisor.supervisor(), [Supervisor.child_spec()], map()) :: snapshot()
  def check(supervisor, specs, last_terminations \\ %{}) when is_list(specs) and is_map(last_terminations) do
    tree = Tree.expected(supervisor, Enum.map(specs, &Tree.child_id/1))
    {expected, missing} = Tree.check(supervisor, tree, [], last_terminations)
    %{expected: expected, healthy: expected - length(missing), missing: missing}
  end

  @spec format(snapshot()) :: String.t()
  def format(snapshot), do: Formatter.format(snapshot)

  @impl true
  def init(opts) do
    state = %{
      supervisor: Keyword.fetch!(opts, :supervisor),
      specs: Keyword.fetch!(opts, :expected_children),
      tree: nil,
      last_terminations: %{},
      monitors: %{},
      missing: MapSet.new(),
      timer: nil,
      interval: Keyword.get(opts, :check_interval, @default_check_interval),
      restart_grace: Keyword.get(opts, :restart_grace, @restart_grace_ms),
      alert_fun: Keyword.get(opts, :alert_fun, alert_fun(opts))
    }

    {:ok, state, {:continue, :check}}
  end

  @impl true
  def handle_continue(:check, state), do: {:noreply, check_and_schedule(state)}

  @impl true
  def handle_call(:status, _from, state) do
    {snapshot, state} = evaluate(state)
    {:reply, {:ok, snapshot}, state}
  rescue
    exception -> unavailable_reply(exception, state)
  catch
    :exit, reason -> unavailable_reply(reason, state)
  end

  @impl true
  def handle_info(:check, state), do: {:noreply, check_and_schedule(state)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {%{path: path}, monitors} ->
        Process.send_after(self(), :check, state.restart_grace)

        state = %{state | monitors: monitors, last_terminations: Map.put(state.last_terminations, path, reason)}

        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp check_and_schedule(state) do
    {_snapshot, state} = evaluate(state)
    schedule_check(state)
  rescue
    exception -> unavailable_check(exception, state)
  catch
    :exit, reason -> unavailable_check(reason, state)
  end

  defp evaluate(state) do
    state = ensure_tree(state)
    {expected, missing_children} = Tree.check(state.supervisor, state.tree, [], state.last_terminations)
    snapshot = %{expected: expected, healthy: expected - length(missing_children), missing: missing_children}
    missing = snapshot.missing |> Enum.map(&{&1.path, &1.reason}) |> MapSet.new()
    changed? = missing != state.missing

    state = state |> Map.put(:missing, missing) |> reconcile_monitors()
    if changed?, do: notify(state.alert_fun, snapshot, missing)

    {snapshot, state}
  end

  defp ensure_tree(%{tree: nil, supervisor: supervisor, specs: specs} = state) do
    %{state | tree: Tree.expected(supervisor, Enum.map(specs, &Tree.child_id/1))}
  end

  defp ensure_tree(state), do: state

  defp notify(alert_fun, snapshot, missing) do
    alert_fun.(snapshot, missing)
  rescue
    exception -> log_alert_failure(exception)
  catch
    :exit, reason -> log_alert_failure(reason)
  end

  defp schedule_check(%{timer: timer, interval: interval} = state) do
    if timer, do: Process.cancel_timer(timer)
    %{state | timer: Process.send_after(self(), :check, interval)}
  end

  defp reconcile_monitors(state) do
    monitored_paths = Map.values(state.monitors) |> Enum.map(& &1.path) |> MapSet.new()

    new_monitors =
      Tree.monitored(state.supervisor, state.tree, [])
      |> Enum.reduce(state.monitors, fn %{path: path, pid: pid} = child, acc ->
        if MapSet.member?(monitored_paths, path), do: acc, else: Map.put(acc, Process.monitor(pid), child)
      end)

    %{state | monitors: new_monitors}
  rescue
    exception -> log_monitor_failure(exception, state)
  catch
    :exit, reason -> log_monitor_failure(reason, state)
  end

  defp alert_fun(opts) do
    alert_opts = Keyword.get(opts, :alert_opts, [])
    fn snapshot, missing_ids -> emit_alert(snapshot, missing_ids, alert_opts) end
  end

  defp emit_alert(%{missing: []}, _missing_ids, opts) do
    Alerts.emit_system("system.supervision.degraded.resolved", Keyword.merge(opts, message: "Supervision healthy", needs_attention: false))
  end

  defp emit_alert(snapshot, _missing_ids, opts) do
    Alerts.emit_system(
      "system.supervision.degraded",
      Keyword.merge(opts,
        message: format(snapshot),
        reason: Enum.map_join(snapshot.missing, ", ", &Formatter.format_missing/1),
        needs_attention: true
      )
    )
  end

  defp unavailable_reply(reason, state) do
    Logger.warning("supervision health status check unavailable: #{inspect(reason)}")
    {:reply, {:error, :unavailable}, state}
  end

  defp unavailable_check(reason, state) do
    Logger.warning("supervision health periodic check failed: #{inspect(reason)}")
    schedule_check(state)
  end

  defp log_alert_failure(reason) do
    Logger.warning("supervision health alert delivery failed: #{inspect(reason)}")
    :ok
  end

  defp log_monitor_failure(reason, state) do
    Logger.warning("supervision health monitor reconciliation failed: #{inspect(reason)}")
    state
  end
end
