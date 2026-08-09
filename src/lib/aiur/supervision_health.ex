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

  @doc """
  Takes a single cheap snapshot of a supervisor against the child specs used
  to start it. This pure entry point makes the expected-process contract
  directly testable without depending on the application's running tree.
  """
  @spec check(Supervisor.supervisor(), [Supervisor.child_spec()], map()) :: snapshot()
  def check(supervisor, specs, last_terminations \\ %{}) when is_list(specs) and is_map(last_terminations) do
    tree = expected_tree(supervisor, Enum.map(specs, &child_id/1))
    {expected, missing} = check_tree(supervisor, tree, [], last_terminations)
    %{expected: expected, healthy: expected - length(missing), missing: missing}
  end

  @spec format(snapshot()) :: String.t()
  def format(%{expected: expected, healthy: healthy, missing: []}), do: "SUPERVISION #{healthy}/#{expected} healthy"

  def format(%{expected: expected, healthy: healthy, missing: missing}) do
    details = Enum.map_join(missing, ", ", &format_missing/1)
    "SUPERVISION #{healthy}/#{expected} — #{details}"
  end

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
      alert_fun: Keyword.get(opts, :alert_fun, &emit_alert/2)
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
    _exception -> {:reply, {:error, :unavailable}, state}
  catch
    :exit, _reason -> {:reply, {:error, :unavailable}, state}
  end

  @impl true
  def handle_info(:check, state), do: {:noreply, check_and_schedule(state)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {%{path: path}, monitors} ->
        Process.send_after(self(), :check, state.restart_grace)

        state =
          %{state | monitors: monitors}
          |> record_termination(path, reason)

        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp check_and_schedule(state) do
    {_snapshot, state} = evaluate(state)
    schedule_check(state)
  rescue
    _exception -> schedule_check(state)
  catch
    :exit, _reason -> schedule_check(state)
  end

  defp evaluate(state) do
    state = ensure_tree(state)
    {expected, missing_children} = check_tree(state.supervisor, state.tree, [], state.last_terminations)
    snapshot = %{expected: expected, healthy: expected - length(missing_children), missing: missing_children}
    missing = snapshot.missing |> Enum.map(&{&1.path, &1.reason}) |> MapSet.new()
    changed? = missing != state.missing

    state = state |> Map.put(:missing, missing) |> reconcile_monitors()
    if changed?, do: notify(state.alert_fun, snapshot, missing)

    {snapshot, state}
  end

  defp ensure_tree(%{tree: nil, supervisor: supervisor, specs: specs} = state) do
    %{state | tree: expected_tree(supervisor, Enum.map(specs, &child_id/1))}
  end

  defp ensure_tree(state), do: state

  defp notify(alert_fun, snapshot, missing) do
    alert_fun.(snapshot, missing)
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp schedule_check(%{timer: timer, interval: interval} = state) do
    if timer, do: Process.cancel_timer(timer)
    %{state | timer: Process.send_after(self(), :check, interval)}
  end

  defp reconcile_monitors(state) do
    monitored_paths = Map.values(state.monitors) |> Enum.map(& &1.path) |> MapSet.new()

    new_monitors =
      monitored_children(state.supervisor, state.tree, [])
      |> Enum.reduce(state.monitors, fn %{path: path, pid: pid} = child, acc ->
        if MapSet.member?(monitored_paths, path), do: acc, else: Map.put(acc, Process.monitor(pid), child)
      end)

    %{state | monitors: new_monitors}
  rescue
    _exception -> state
  catch
    :exit, _reason -> state
  end

  defp emit_alert(%{missing: []}, _missing_ids) do
    Alerts.emit_system("system.supervision.degraded.resolved", message: "Supervision healthy", needs_attention: false)
  end

  defp emit_alert(snapshot, _missing_ids) do
    Alerts.emit_system("system.supervision.degraded",
      message: format(snapshot),
      reason: Enum.map_join(snapshot.missing, ", ", &format_missing/1),
      needs_attention: true
    )
  end

  defp expected_tree(supervisor, ids) do
    children = Supervisor.which_children(supervisor) |> Map.new(&{elem(&1, 0), &1})

    nested =
      Map.new(ids, fn id ->
        child_tree =
          case Map.get(children, id) do
            {^id, pid, :supervisor, _modules} when is_pid(pid) -> expected_tree(pid, static_child_ids(pid))
            _child -> nil
          end

        {id, child_tree}
      end)

    %{ids: ids, nested: nested}
  end

  defp check_tree(supervisor, %{ids: expected_ids, nested: nested}, path, last_terminations) do
    children = Supervisor.which_children(supervisor) |> Map.new(&{elem(&1, 0), &1})

    Enum.reduce(expected_ids, {0, []}, fn id, {expected, missing} ->
      check_child({expected, missing}, Map.get(children, id), nested[id], id, path, last_terminations)
    end)
  end

  defp check_child({expected, missing}, {id, pid, :supervisor, _modules}, tree, id, path, last_terminations) when is_pid(pid) do
    check_supervisor_child({expected, missing}, pid, tree, id, path, last_terminations)
  end

  defp check_child({expected, missing}, {id, pid, _type, _modules}, _tree, id, _path, _last_terminations) when is_pid(pid),
    do: {expected + 1, missing}

  defp check_child({expected, missing}, _child, tree, id, path, last_terminations) do
    child_path = path ++ [id]
    down = %{id: id, path: child_path, reason: termination_reason(last_terminations, child_path, id)}
    descendants = missing_descendants(tree, child_path)
    {expected + 1 + length(descendants), [down | descendants ++ missing]}
  end

  defp check_supervisor_child({expected, missing}, _pid, nil, _id, _path, _last_terminations), do: {expected + 1, missing}

  defp check_supervisor_child({expected, missing}, pid, tree, id, path, last_terminations) do
    {nested_expected, nested_missing} = check_tree(pid, tree, path ++ [id], last_terminations)
    {expected + 1 + nested_expected, missing ++ nested_missing}
  end

  defp missing_descendants(nil, _path), do: []

  defp missing_descendants(%{ids: ids, nested: nested}, path) do
    Enum.flat_map(ids, fn id ->
      down = %{id: id, path: path ++ [id], reason: nil}
      [down | missing_descendants(nested[id], path ++ [id])]
    end)
  end

  # `which_children/1` preserves static supervisor child IDs even while a
  # temporary child is down. DynamicSupervisor runtime children use
  # `:undefined`, so excluding that ID keeps ephemeral agent/session workers
  # out of the fixed liveness contract without a hand-maintained list.
  defp static_child_ids(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&(&1 == :undefined))
  end

  defp child_id(spec), do: spec |> Supervisor.child_spec([]) |> Map.fetch!(:id)

  defp monitored_children(supervisor, %{ids: ids, nested: nested}, path) do
    children = Supervisor.which_children(supervisor) |> Map.new(&{elem(&1, 0), &1})

    Enum.flat_map(ids, fn id ->
      monitored_child(Map.get(children, id), nested[id], path, id)
    end)
  end

  defp monitored_child({id, pid, type, _modules}, tree, path, id) when is_pid(pid) do
    child = %{path: path ++ [id], pid: pid, type: type}
    [child | monitored_descendants(child, tree)]
  end

  defp monitored_child(_child, _tree, _path, _id), do: []

  defp monitored_descendants(%{pid: pid, type: :supervisor, path: path}, tree) when not is_nil(tree),
    do: monitored_children(pid, tree, path)

  defp monitored_descendants(_child, _tree), do: []

  defp record_termination(state, path, reason) do
    %{state | last_terminations: Map.put(state.last_terminations, path, reason)}
  end

  defp termination_reason(last_terminations, path, id), do: Map.get(last_terminations, path) || Map.get(last_terminations, id)

  defp format_missing(%{id: id, path: path, reason: nil}), do: "#{display_path(path, id)} DOWN"

  defp format_missing(%{id: id, path: path, reason: reason}),
    do: "#{display_path(path, id)} DOWN (last termination: #{inspect(reason)})"

  defp format_missing(%{id: id, reason: nil}), do: "#{display_id(id)} DOWN"
  defp format_missing(%{id: id, reason: reason}), do: "#{display_id(id)} DOWN (last termination: #{inspect(reason)})"

  defp display_path([_ | _] = path, _id), do: Enum.map_join(path, "/", &display_id/1)
  defp display_path(_, id), do: display_id(id)

  defp display_id(id) when is_atom(id), do: id |> Module.split() |> Enum.join(".")
  defp display_id(id), do: inspect(id)
end
