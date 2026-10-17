defmodule Aiur.TestSupport.LifecycleLeakGuard do
  @moduledoc """
  Suite guard against agent runners that outlive their test (#4733).

  The lifecycle recorder is global app env, so a runner a finished test left
  alive writes its records into whichever test is running now. In the suite
  this module wraps the `:signal` lifecycle sink, the path runner writes take.
  It drops a write from a process whose `$callers` or `$ancestors` chain
  reaches a finished `Aiur.TestSupport` test (one whose teardown completed),
  kills that process, and the next test teardown fails naming that test.
  """

  alias Aiur.RunTelemetry.Lifecycle

  @tests __MODULE__.Tests
  @leaks __MODULE__.Leaks
  @owners __MODULE__.Owners

  @doc "Creates the suite tables; call once from the long-lived test_helper process."
  def start! do
    :ets.new(@tests, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@leaks, [:named_table, :public, :bag])
    :ets.new(@owners, [:named_table, :public, :set])
    :ok
  end

  @doc "Registers the calling test process, makes sure the guard sink is installed, and returns the test pid."
  def track(%{module: module, test: test}) do
    :ets.insert(@tests, {self(), "#{inspect(module)} #{test}", false})
    signal = Application.get_env(:aiur, :signal, [])

    if signal[:lifecycle_sink] == Lifecycle,
      do: Application.put_env(:aiur, :signal, Keyword.put(signal, :lifecycle_sink, __MODULE__))

    self()
  end

  @doc "Marks a test finished; its processes' teardown writes before this point are not leaks."
  def finish(test_pid) do
    :ets.update_element(@tests, test_pid, {3, true})
    :ok
  end

  @doc "Teardown's last step: marks the test finished, raises its scope violation, then checks for leaks."
  def finish!(test_pid, scope_violation) do
    runner_leaks = live_runners(test_pid)

    stop_owned_runners(test_pid)

    finish(test_pid)

    cond do
      scope_violation -> raise(scope_violation)
      runner_leaks != [] -> raise "test left dispatched agent runners alive: #{inspect(Enum.map(runner_leaks, fn {pid, test} -> {test, pid} end))}"
      true -> check!()
    end
  end

  def stop_owned_runners(test_pid) when is_pid(test_pid) do
    live_runners(test_pid)
    |> Enum.each(fn {runner, _test} ->
      Process.exit(runner, :kill)
      await_down(runner)
    end)

    :ok
  end

  @doc "Raises once for every lifecycle write a finished test's process made."
  def check! do
    case :ets.take(@leaks, :leak) do
      [] ->
        :ok

      leaks ->
        lines = Enum.map_join(leaks, "\n", fn {:leak, test, writer, event} -> "  #{test}: #{inspect(writer)} wrote #{event}" end)
        raise "a process from a finished test still writes lifecycle records; stop it in on_exit:\n" <> lines
    end
  end

  def record(ticket, attempt_id, event, boundary, metadata \\ %{}, opts \\ []) do
    if leaked?(event), do: :ok, else: Lifecycle.record(ticket, attempt_id, event, boundary, metadata, opts)
  end

  def observe_backend_message(ticket, attempt_id, backend, message, opts \\ []) do
    if leaked?("backend_message"), do: :ok, else: Lifecycle.observe_backend_message(ticket, attempt_id, backend, message, opts)
  end

  defp leaked?(event) do
    with test_pid when is_pid(test_pid) <- owner(self(), []),
         [{^test_pid, test, true}] <- :ets.lookup(@tests, test_pid) do
      :ets.insert(@leaks, {:leak, test, {self(), Process.get(:"$initial_call")}, event})
      # One report per leak: a live leaker would fail every later teardown too.
      Process.exit(self(), :kill)
    else
      _ -> false
    end
  end

  defp live_runners(test_pid) do
    Process.list()
    |> Enum.filter(fn pid ->
      match?({Aiur.Orchestrator.Dispatcher.Launch, _, _}, dictionary_value(pid, :"$initial_call", nil)) and
        runner_owner(pid, []) == test_pid
    end)
    |> Enum.map(&{&1, test_name(test_pid)})
    |> Enum.filter(fn {runner, _test} -> Process.alive?(runner) end)
  end

  defp runner_owner(pid, seen) do
    cond do
      :ets.member(@tests, pid) ->
        pid

      [{^pid, test_pid}] <- :ets.lookup(@owners, pid) ->
        test_pid

      pid not in seen and Process.alive?(pid) ->
        Enum.find_value(parents(pid), &runner_owner(&1, [pid | seen]))

      true ->
        nil
    end
  end

  defp await_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> Process.demonitor(ref, [:flush])
    end
  end

  defp test_name(test_pid) do
    case :ets.lookup(@tests, test_pid) do
      [{^test_pid, test, _finished}] -> test
      _ -> "unknown test"
    end
  end

  # Depth-first through live processes' callers and ancestors to a registered
  # test. Each process on the found path is cached, so a runner still resolves
  # after the orchestrator that spawned it has died.
  defp owner(pid, seen) do
    case {:ets.member(@tests, pid), :ets.lookup(@owners, pid)} do
      {true, _} ->
        pid

      {false, [{^pid, test_pid}]} ->
        test_pid

      {false, []} ->
        if pid not in seen and Process.alive?(pid) do
          parent_owner = Enum.find_value(parents(pid), &owner(&1, [pid | seen]))
          cache_owner(pid, parent_owner)
        end
    end
  end

  defp cache_owner(_pid, nil), do: nil

  defp cache_owner(pid, test_pid) do
    :ets.insert(@owners, {pid, test_pid})
    test_pid
  end

  defp parents(pid) do
    dictionary = if pid == self(), do: Process.get(), else: elem(Process.info(pid, :dictionary) || {:dictionary, []}, 1)

    (Keyword.get(dictionary, :"$callers", []) ++ Keyword.get(dictionary, :"$ancestors", []))
    |> Enum.map(fn
      name when is_atom(name) -> Process.whereis(name)
      pid -> pid
    end)
    |> Enum.filter(&is_pid/1)
  end

  defp callers(pid), do: dictionary_value(pid, :"$callers", [])
  defp ancestors(pid), do: dictionary_value(pid, :"$ancestors", [])

  defp dictionary_value(pid, key, default) do
    case Process.info(pid, {:dictionary, key}) do
      {_key, :undefined} -> default
      {_key, value} -> value
      nil -> []
    end
  end
end
