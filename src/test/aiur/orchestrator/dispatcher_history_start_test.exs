defmodule Aiur.Orchestrator.DispatcherHistoryStartTest do
  use Aiur.TestSupport
  alias Aiur.BuildOrder.History
  alias Aiur.Orchestrator.{Dispatcher, State}

  test "confirmed dispatch journals a start with telemetry disabled" do
    key = {Aiur.RunTelemetry, :telemetry_enabled}
    prior = :persistent_term.get(key, :unset)
    :persistent_term.put(key, false)
    on_exit(fn -> if prior == :unset, do: :persistent_term.erase(key), else: :persistent_term.put(key, prior) end)
    dir = Aiur.TestSupport.tmp_root!("dispatch-history")
    on_exit(fn -> File.rm_rf!(dir) end)
    pid = start_supervised!({History, name: __MODULE__.Store, repository: "acme/widgets", state_dir: dir, flush_ms: 60_000})
    issue = %Aiur.Issue{id: "71", identifier: "71", title: "timing", state: "todo", selected_backend: "codex"}
    original = Process.whereis(History)
    if original, do: Process.unregister(History)
    Process.unregister(__MODULE__.Store)
    Process.register(pid, History)

    on_exit(fn ->
      if Process.whereis(History) == pid, do: Process.unregister(History)
      if original && Process.alive?(original), do: Process.register(original, History)
    end)

    before = DateTime.utc_now()
    parent = self()

    runner = fn _, _, _ ->
      send(parent, {:runner, self()})
      receive do: (:release -> :ok)
    end

    state = Dispatcher.do_dispatch_issue(%State{max_concurrent_agents: 1, effective_concurrent_agents: 1}, issue, nil, nil, runner: runner, rework_head_sha: nil)
    assert Map.has_key?(state.running, "71")
    assert {:ok, snapshot} = History.snapshot()
    row = snapshot.rows[71]
    assert DateTime.compare(row.dispatched_at, before) != :lt
    assert {row.start, row.start_source} == {row.dispatched_at, :dispatch}
    receive_barrier({:runner, pid})
    send(pid, :release)
  end

  test "failed spawn does not journal a dispatch start" do
    dir = Aiur.TestSupport.tmp_root!("failed-dispatch-history")
    on_exit(fn -> File.rm_rf!(dir) end)
    history = start_supervised!({History, name: __MODULE__.Store, repository: "acme/widgets", state_dir: dir})
    tasks = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks, max_children: 0})
    issue = %Aiur.Issue{id: "72", identifier: "72", title: "timing", state: "todo", selected_backend: "codex"}

    with_name(history, History, fn ->
      with_name(tasks, Aiur.TaskSupervisor, fn ->
        state = Dispatcher.do_dispatch_issue(%State{max_concurrent_agents: 1, effective_concurrent_agents: 1}, issue, nil, nil)
        refute Map.has_key?(state.running, "72")
        assert {:ok, snapshot} = History.snapshot()
        assert snapshot.rows == %{}
      end)
    end)
  end

  defp with_name(pid, name, fun) do
    original = Process.whereis(name)
    if original, do: Process.unregister(name)
    {:registered_name, private} = Process.info(pid, :registered_name)
    Process.unregister(private)
    Process.register(pid, name)

    try do
      fun.()
    after
      Process.unregister(name)
      Process.register(pid, private)
      if original && Process.alive?(original), do: Process.register(original, name)
    end
  end
end
