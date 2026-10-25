defmodule Aiur.TestSupport.LifecycleLeakGuard do
  @moduledoc """
  Suite guard against agent runners and tool executors that outlive their test.

  The lifecycle recorder is global app env, so a runner a finished test left
  alive writes its records into whichever test is running now. In the suite
  this module wraps the `:signal` lifecycle sink, the path runner writes take.
  It drops a write from a process whose `$callers` or `$ancestors` chain
  reaches a finished `Aiur.TestSupport` test (one whose teardown completed),
  records the finding, and kills the process only in fail mode. Report mode
  records findings without changing other tests' outcomes.
  """

  alias Aiur.RunTelemetry.Lifecycle

  @tests __MODULE__.Tests
  @leaks __MODULE__.Leaks
  @owners __MODULE__.Owners
  @mode_env "AIUR_LIFECYCLE_LEAK_GUARD_MODE"
  @report_env "AIUR_LIFECYCLE_LEAK_REPORT"

  @doc "Creates the suite tables; call once from the long-lived test_helper process."
  def start! do
    :ets.new(@tests, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@leaks, [:named_table, :public, :bag])
    :ets.new(@owners, [:named_table, :public, :set])
    :ok
  end

  @doc "Returns whether findings are fatal; defaults to report-only for staged rollout."
  def mode, do: if(System.get_env(@mode_env) == "fail", do: :fail, else: :report)

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

  @doc "Teardown's last step: marks the test finished and reports leaks captured before cleanup."
  def finish!(test_pid, scope_violation, runner_leaks \\ nil) do
    runner_leaks = runner_leaks || live_owned_processes(test_pid)
    stop_runners(runner_leaks)

    finish(test_pid)

    cond do
      scope_violation -> raise(scope_violation)
      runner_leaks != [] -> report_or_fail!(Enum.map(runner_leaks, fn {pid, test} -> finding(test, "owned lifecycle process #{inspect(pid)} remained alive at teardown") end))
      true -> check!()
    end
  end

  def fail_mode?, do: mode() == :fail

  def install_late_log_handler! do
    case :logger.add_handler(__MODULE__.LogHandler, __MODULE__.LogHandler, %{level: :warning}) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
      {:error, reason} -> raise "could not install lifecycle leak log handler: #{inspect(reason)}"
    end
  end

  def stop_owned_runners(test_pid) when is_pid(test_pid) do
    if Process.whereis(Aiur.TaskSupervisor) do
      Aiur.TaskSupervisor
      |> Task.Supervisor.children()
      |> Enum.filter(fn pid -> launch_runner?(pid) and runner_owner(pid, []) == test_pid end)
      |> Enum.map(&{&1, test_name(test_pid)})
      |> stop_runners()
    end

    :ok
  end

  defp stop_runners(runner_leaks) do
    Enum.each(runner_leaks, fn {runner, _test} ->
      if Process.alive?(runner) do
        Process.exit(runner, :kill)
        await_down(runner)
      end
    end)

    :ok
  end

  @doc "Raises once for every lifecycle write a finished test's process made."
  def check! do
    case :ets.take(@leaks, :leak) do
      [] ->
        :ok

      leaks ->
        findings = Enum.map(leaks, fn {:leak, test, writer, event} -> finding(test, "#{inspect(writer)} wrote lifecycle event #{event}") end)
        report_or_fail!(findings)
    end
  end

  def record(ticket, attempt_id, event, boundary, metadata \\ %{}, opts \\ []) do
    if leaked?(event), do: :ok, else: Lifecycle.record(ticket, attempt_id, event, boundary, metadata, opts)
  end

  def record!(ticket, attempt_id, event, boundary, metadata \\ %{}, opts \\ []),
    do: record(ticket, attempt_id, event, boundary, metadata, opts)

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

  @doc false
  def report_late_log(pid, message) do
    case owner(pid, []) do
      test_pid when is_pid(test_pid) ->
        case :ets.lookup(@tests, test_pid) do
          [{^test_pid, test, true}] ->
            report_finished_test_log(pid, test, message)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp report_finished_test_log(pid, test, message) do
    :ets.insert(@leaks, {:leak, test, {pid, dictionary_value(pid, :"$initial_call", nil)}, "late log: #{message}"})
    maybe_kill_late_logger(pid)
  end

  defp maybe_kill_late_logger(pid) do
    if fail_mode?(), do: Process.exit(pid, :kill)
  end

  def owner_for_log(pid) do
    case owner(pid, []) do
      test_pid when is_pid(test_pid) ->
        case :ets.lookup(@tests, test_pid) do
          [{^test_pid, test, true}] -> {:finished, test}
          [{^test_pid, test, false}] -> {:active, test}
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  end

  defp finding(test, detail), do: "#{test}: #{detail}"

  defp report_or_fail!(findings) do
    report = Enum.join(findings, "\n")

    case System.get_env(@report_env) do
      path when is_binary(path) ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, report <> "\n", [:append])

      _ ->
        IO.puts(:stderr, "Lifecycle leak guard findings:\n" <> report)
    end

    if mode() == :fail, do: raise("lifecycle leak guard failed:\n" <> report), else: :ok
  end

  @doc false
  def live_runners(test_pid) do
    Process.list()
    |> Enum.filter(fn pid ->
      match?({Aiur.Orchestrator.Dispatcher.Launch, _, _}, dictionary_value(pid, :"$initial_call", nil)) and
        runner_owner(pid, []) == test_pid
    end)
    |> Enum.map(&{&1, test_name(test_pid)})
    |> Enum.filter(fn {runner, _test} -> Process.alive?(runner) end)
  end

  @doc false
  def live_owned_processes(test_pid) do
    Process.list()
    |> Enum.filter(fn pid -> Process.alive?(pid) and owned_process?(pid) and runner_owner(pid, []) == test_pid end)
    |> Enum.map(&{&1, test_name(test_pid)})
  end

  defp runner_owner(pid, seen) do
    case {:ets.member(@tests, pid), :ets.lookup(@owners, pid)} do
      {true, _} ->
        pid

      {false, [{^pid, test_pid}]} ->
        test_pid

      {false, []} ->
        if pid not in seen and Process.alive?(pid) do
          Enum.find_value(parents(pid), &runner_owner(&1, [pid | seen]))
        end
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

  defp dictionary_value(pid, key, default) do
    case Process.info(pid, {:dictionary, key}) do
      {_key, :undefined} -> default
      {_key, value} -> value
      nil -> default
    end
  end

  defp launch_runner?(pid),
    do: match?({Aiur.Orchestrator.Dispatcher.Launch, _, _}, dictionary_value(pid, :"$initial_call", nil))

  defp owned_process?(pid), do: launch_runner?(pid) or executor_or_poller?(pid)

  @doc false
  def stop_owned_processes(processes), do: stop_runners(processes)

  defp executor_or_poller?(pid) do
    case dictionary_value(pid, :"$initial_call", nil) do
      {module, _, _} when module in [Aiur.AgentRunner.ToolExecutor, Aiur.Events.GithubCIPoller, Aiur.Events.GithubCommentsPoller] ->
        true

      _ ->
        false
    end
  end
end

defmodule Aiur.TestSupport.LifecycleLeakGuard.LogHandler do
  @moduledoc "Attributes late warning and error logs to the test-owned process that emitted them."
  @behaviour :logger_handler

  alias Aiur.TestSupport.LifecycleLeakGuard

  def adding_handler(config), do: {:ok, config}
  def changing_config(_set_or_update, _old, new), do: {:ok, new}
  def removing_handler(_config), do: :ok

  def log(%{level: level, msg: msg, meta: %{pid: pid}}, config) when level in [:warning, :error] do
    case LifecycleLeakGuard.owner_for_log(pid) do
      {:finished, _test_name} ->
        LifecycleLeakGuard.report_late_log(pid, inspect(msg))
        :ok

      _ ->
        :ok
    end

    config
  end

  def log(_event, config), do: config
end
