# Cohesion: shared suite state, test lifecycle events, and leak reporting all
# belong here because the formatter and ExUnit callbacks must agree on the
# same test identity and recovery ledger.
defmodule Aiur.TestSupport.OrchestratorGuard do
  @moduledoc """
  Names the test that leaves the shared `Aiur.Orchestrator` down (#4909).

  It is also an ExUnit formatter that remembers the last finished test of any
  case template, so the shared setup can say who ran before it had to restart
  the orchestrator. The shared teardown fails a sync test that ends with the
  orchestrator down, so the leaking test fails itself instead of its
  successors. "Down" also covers a stand-in left holding the name while the
  supervised child is unnamed. A plain `ExUnit.Case` leak is recorded when the
  next sync `Aiur.TestSupport` setup has to restore it, or when the suite ends
  with it broken, and `verify_suite!/0` then fails the run.

  Leaks are never judged inside the formatter: its events are casts that land
  after later tests have started, so what it would see belongs to them.
  """
  use GenServer

  alias Aiur.GitHub.CodeOwners
  alias Aiur.TestSupport.OrchestratorChild
  alias Aiur.TestSupport.SupervisorExit

  alias Aiur.TestSupport.RuntimeChildren

  # persistent_term, not GenServer state: after_suite callbacks run once formatters have stopped.
  @suite_leaks_key {__MODULE__, :suite_leaks}
  @runtime_child_leaks_key {__MODULE__, :runtime_child_leaks}
  @instance_key_key {__MODULE__, :instance_key}
  @app_env_key {__MODULE__, :app_env}
  @codeowners_key {__MODULE__, :codeowners}
  @last_finished_key {__MODULE__, :last_finished}
  @guarded_app_env_keys [:decision_state_dir, :github_budget_dir, :executor_state_dir, :runtime_state_dir]

  @impl true
  def init(_opts) do
    Process.register(self(), __MODULE__)
    :persistent_term.put(@suite_leaks_key, [])
    :persistent_term.put(@runtime_child_leaks_key, [])
    :persistent_term.put(@instance_key_key, System.get_env("AIUR_INSTANCE_KEY"))
    :persistent_term.put(@app_env_key, capture_app_env())
    :persistent_term.put(@codeowners_key, :unset)
    :persistent_term.put(@last_finished_key, nil)
    SupervisorExit.start_monitoring()
    {:ok, nil}
  end

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{state: {tag, _}}}, last) when tag in [:excluded, :skipped, :invalid],
    do: {:noreply, last}

  def handle_cast({:test_finished, %ExUnit.Test{} = test}, _last) do
    name = "#{inspect(test.module)}: #{test.name}"
    :persistent_term.put(@last_finished_key, name)
    {:noreply, name}
  end

  def handle_cast(_event, last), do: {:noreply, last}

  @impl true
  def handle_info(message, last), do: SupervisorExit.handle_info(message, last)

  @impl true
  def handle_call({:monitor_supervisor, name, notify_pid}, _from, last) do
    SupervisorExit.start_monitoring(name, notify_pid)
    {:reply, :ok, last}
  end

  def handle_call(:last_finished, _from, last), do: {:reply, last, last}

  @doc false
  def monitor_supervisor(name, notify_pid \\ nil),
    do: GenServer.call(__MODULE__, {:monitor_supervisor, name, notify_pid})

  @doc "Fails the suite when a plain ExUnit case leaked the orchestrator. Runs after the formatters stop."
  @spec verify_suite!() :: :ok
  def verify_suite! do
    if leak = leak(), do: record_leak(:persistent_term.get(@last_finished_key, nil), leak)

    runtime_child_leaks = missing_runtime_children()

    if runtime_child_leaks != [] do
      last = :persistent_term.get(@last_finished_key, nil)
      Enum.each(runtime_child_leaks, &record_runtime_child_leak(last, &1))
    end

    errors = suite_errors()
    restore_missing_runtime_children()

    case errors do
      [] -> :ok
      errors -> raise Enum.join(errors, "\n")
    end
  end

  defp suite_errors do
    suite_state_errors() ++ suite_orchestrator_errors() ++ suite_runtime_child_errors()
  end

  defp suite_state_errors do
    expected_instance_key = :persistent_term.get(@instance_key_key, nil)
    actual_instance_key = System.get_env("AIUR_INSTANCE_KEY")

    app_env_leaks = app_env_leaks()
    instance_key_leak = if actual_instance_key == expected_instance_key, do: [], else: ["AIUR_INSTANCE_KEY changed from #{inspect(expected_instance_key)} to #{inspect(actual_instance_key)}"]
    store_leaks = decision_store_leaks()
    state_leaks = app_env_leaks ++ instance_key_leak ++ codeowners_leaks() ++ store_leaks

    if state_leaks == [] do
      []
    else
      last = :persistent_term.get(@last_finished_key, nil) || "unknown"
      ["test suite found shared state changed after #{last} (upper bound only; plain-test culprit is unknown): #{Enum.join(state_leaks, "; ")}"]
    end
  end

  defp suite_orchestrator_errors do
    case :persistent_term.get(@suite_leaks_key, []) do
      [] -> []
      leaks -> ["plain ExUnit tests broke Aiur.Orchestrator: #{Enum.join(leaks, ", ")}"]
    end
  end

  defp suite_runtime_child_errors do
    case :persistent_term.get(@runtime_child_leaks_key, []) do
      [] ->
        []

      leaks ->
        exit_reason = SupervisorExit.exit_reason()
        reason_note = if is_nil(exit_reason), do: "", else: " (Aiur.Supervisor exit reason: #{inspect(exit_reason)})"
        ["plain ExUnit tests left shared runtime children down: #{Enum.join(leaks, ", ")}#{reason_note}"]
    end
  end

  @doc false
  @spec capture_shared_state() :: %{app_env: %{optional(atom()) => {:ok, term()} | :error}, instance_key: String.t() | nil, codeowners: map() | nil}
  def capture_shared_state do
    %{
      app_env: capture_app_env(),
      instance_key: System.get_env("AIUR_INSTANCE_KEY"),
      codeowners: :persistent_term.get(@codeowners_key, :unset)
    }
  end

  @doc false
  @spec verify_restored_shared_state!([{atom(), {:ok, term()} | :error}], String.t() | nil, map()) :: :ok
  def verify_restored_shared_state!(previous_app_env, previous_instance_key, context) do
    expected = %{
      app_env: Map.new(previous_app_env),
      instance_key: previous_instance_key,
      codeowners: :persistent_term.get(@codeowners_key, :unset)
    }

    verify_restored!(Map.put(context, :aiur_expected_shared_state, expected))
  end

  @doc false
  @spec verify_shared_state_before_test!(map()) :: :ok
  def verify_shared_state_before_test!(%{async: true}), do: :ok

  def verify_shared_state_before_test!(context) do
    expected = :persistent_term.get(@app_env_key, capture_app_env())
    expected_instance_key = :persistent_term.get(@instance_key_key, System.get_env("AIUR_INSTANCE_KEY"))
    state_leaks = restore_test_scope_state(expected, expected_instance_key)
    {runtime_child_leaks, prior_test} = record_missing_runtime_children()

    try do
      if runtime_child_leaks == [] do
        store_leaks = decision_store_leaks()
        store_recovery = recover_decision_store(store_leaks)
        report_before_test_leaks(context, prior_test, state_leaks, store_leaks, store_recovery)
      else
        report_before_test_leaks(context, prior_test, state_leaks, [], :ok)
      end
    after
      restore_missing_runtime_children()
    end

    :ok
  end

  defp restore_test_scope_state(expected, expected_instance_key) do
    actual_instance_key = System.get_env("AIUR_INSTANCE_KEY")
    instance_key_leaks = if actual_instance_key == expected_instance_key, do: [], else: ["AIUR_INSTANCE_KEY changed from #{inspect(expected_instance_key)} to #{inspect(actual_instance_key)}"]
    codeowners_leaks = codeowners_leaks(:persistent_term.get(@codeowners_key, :unset))
    leaks = app_env_leaks() ++ instance_key_leaks ++ codeowners_leaks

    if leaks != [] do
      Enum.each(@guarded_app_env_keys, fn key -> restore_app_env(key, Map.fetch!(expected, key)) end)
      restore_instance_key(expected_instance_key)
      restore_codeowners(:persistent_term.get(@codeowners_key, :unset))
    end

    leaks
  end

  defp record_missing_runtime_children do
    leaks = missing_runtime_children()
    prior_test = if leaks == [], do: nil, else: last_finished()
    Enum.each(leaks, &record_runtime_child_leak(prior_test, &1))
    {leaks, prior_test}
  end

  defp report_before_test_leaks(context, prior_test, state_leaks, store_leaks, store_recovery) do
    recovery_errors = recovery_errors(store_recovery)

    if state_leaks != [] or store_leaks != [] or recovery_errors != [] do
      last = prior_test || last_finished() || "unknown"
      details = Enum.join(state_leaks ++ store_leaks ++ recovery_errors, "; ")
      recovery_status = if recovery_errors == [], do: "restored shared state", else: "failed to restore shared state"

      raise "#{test_name(context)} started after last finished test #{last} (upper bound; plain-test culprit unknown); #{recovery_status}: #{details}"
    end
  end

  defp missing_runtime_children do
    []
    |> maybe_missing(Process.whereis(Aiur.Supervisor), "Aiur.Supervisor")
    |> maybe_missing(Process.whereis(Aiur.PubSub), "Aiur.PubSub")
    |> maybe_missing(if(active_turns_owner_missing?(), do: nil, else: :running), "Aiur.Opencode.ActiveTurns")
    |> maybe_missing(Process.whereis(Aiur.DecisionStore), "Aiur.DecisionStore")
  end

  defp restore_missing_runtime_children do
    if active_turns_owner_missing?(), do: restart_active_turns()
    :ok
  end

  defp active_turns_owner_missing? do
    is_nil(Process.whereis(Aiur.Opencode.ActiveTurns)) and is_pid(Process.whereis(Aiur.Supervisor)) and
      is_pid(Process.whereis(Aiur.PubSub))
  end

  defp restart_active_turns do
    case Supervisor.restart_child(Aiur.Supervisor, Aiur.Opencode.ActiveTurns) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      _ -> if(Process.whereis(Aiur.Opencode.ActiveTurns), do: :ok, else: :error)
    end
  catch
    :exit, _reason -> :error
  end

  defp maybe_missing(missing, nil, child), do: ["#{child} unregistered" | missing]
  defp maybe_missing(missing, _pid, _child), do: missing

  @doc "Restores a missing or stood-in orchestrator before a test and reports the test that ran before it."
  @spec ensure_running(map()) :: :ok | :error
  def ensure_running(context) do
    # Async neighbours may hold the name briefly; only a sync setup proves the previous test leaked it.
    leak = if context[:async], do: if(is_nil(Process.whereis(Aiur.Orchestrator)), do: "down"), else: leak()

    if leak do
      last = last_finished()
      IO.puts(:stderr, "Aiur.Orchestrator was #{leak} before #{test_name(context)}; last finished test: #{last || "unknown"}")
      unless context[:async], do: record_leak(last, leak)
      restore(leak)
    else
      RuntimeChildren.ensure_orchestrator_running()
    end
  end

  @doc """
  Raises when a sync test ends with the orchestrator down or its name held by
  a stand-in, after restoring it. Async tests are skipped: a concurrent sibling
  may hold the name briefly.
  """
  @spec verify_restored!(map()) :: :ok
  def verify_restored!(%{async: true}), do: :ok

  def verify_restored!(context) do
    # A call on the supervisor processes any child exit already in its mailbox.
    RuntimeChildren.supervisor_accepting_calls?(Process.whereis(Aiur.Supervisor), 1_000)

    pubsub_leak = is_nil(Process.whereis(Aiur.PubSub))
    active_turns_leak = active_turns_owner_missing?()
    orchestrator_leak = leak()
    orchestrator_restore = if orchestrator_leak, do: restore(orchestrator_leak)
    pubsub_errors = restore_and_report_pubsub(pubsub_leak, context)
    active_turns_errors = restore_and_report_active_turns(active_turns_leak, context)
    shared_leaks = verify_shared_state_restored!(context)
    store_leaks = decision_store_leaks()
    store_recovery = recover_decision_store(store_leaks)

    orchestrator_errors =
      if orchestrator_leak do
        [
          "#{test_name(context)} left Aiur.Orchestrator #{orchestrator_leak} (restore: #{inspect(orchestrator_restore)}). Restore it in on_exit with Aiur.TestSupport.ensure_orchestrator_running/0 or await_supervised_restart/3."
        ]
      else
        []
      end

    recovery_errors = recovery_errors(store_recovery)

    shared_state_errors =
      if shared_leaks == [] and store_leaks == [] and recovery_errors == [],
        do: [],
        else: [
          "#{test_name(context)} left shared test state changed (#{if(recovery_errors == [], do: "restored", else: "restore failed")}): #{Enum.join(shared_leaks ++ store_leaks ++ recovery_errors, "; ")}"
        ]

    errors = orchestrator_errors ++ pubsub_errors ++ active_turns_errors ++ shared_state_errors
    if active_turns_leak, do: restart_active_turns()

    if errors != [], do: raise(Enum.join(errors, "\n"))

    :ok
  end

  defp restore_and_report_pubsub(false, _context), do: []

  defp restore_and_report_pubsub(true, context) do
    restore = RuntimeChildren.ensure_pubsub_running()
    ["#{test_name(context)} left Aiur.PubSub unregistered (restore: #{inspect(restore)}). Restore it in on_exit with Aiur.TestSupport.ensure_pubsub_running/0."]
  end

  defp restore_and_report_active_turns(false, _context), do: []

  defp restore_and_report_active_turns(true, context) do
    ["#{test_name(context)} left Aiur.Opencode.ActiveTurns down."]
  end

  defp capture_app_env do
    Map.new(@guarded_app_env_keys, &{&1, Application.fetch_env(:aiur, &1)})
  end

  defp app_env_leaks do
    expected = :persistent_term.get(@app_env_key, capture_app_env())

    Enum.flat_map(@guarded_app_env_keys, fn key ->
      before = Map.fetch!(expected, key)
      current = Application.fetch_env(:aiur, key)
      if current == before, do: [], else: ["Application :aiur, #{inspect(key)} changed from #{inspect(before)} to #{inspect(current)}"]
    end)
  end

  defp verify_shared_state_restored!(%{aiur_expected_shared_state: expected}) do
    actual_instance_key = System.get_env("AIUR_INSTANCE_KEY")
    expected_instance_key = expected.instance_key

    app_env_leaks =
      Enum.flat_map(@guarded_app_env_keys, fn key ->
        before = Map.fetch!(expected.app_env, key)
        current = Application.fetch_env(:aiur, key)
        if current == before, do: [], else: ["Application :aiur, #{inspect(key)} changed from #{inspect(before)} to #{inspect(current)}"]
      end)

    instance_key_leaks = if actual_instance_key == expected_instance_key, do: [], else: ["AIUR_INSTANCE_KEY changed from #{inspect(expected_instance_key)} to #{inspect(actual_instance_key)}"]
    expected_codeowners = Map.get(expected, :codeowners, :unset)
    codeowners_leaks = codeowners_leaks(expected_codeowners)
    leaks = app_env_leaks ++ instance_key_leaks ++ codeowners_leaks

    if leaks != [] do
      Enum.each(@guarded_app_env_keys, fn key -> restore_app_env(key, Map.fetch!(expected.app_env, key)) end)
      restore_instance_key(expected_instance_key)
      restore_codeowners(expected_codeowners)
    end

    leaks
  end

  defp verify_shared_state_restored!(_context) do
    leaks = codeowners_leaks()
    if leaks != [], do: restore_codeowners(:persistent_term.get(@codeowners_key, :unset))
    leaks
  end

  def capture_codeowners_baseline! do
    case codeowners_state() do
      nil -> :ok
      state -> :persistent_term.put(@codeowners_key, state)
    end
  end

  @doc false
  def restore_codeowners_state!(state), do: restore_codeowners(state)

  @doc false
  def restore_codeowners_baseline!, do: restore_codeowners(:persistent_term.get(@codeowners_key, :unset))

  defp codeowners_leaks(expected \\ :persistent_term.get(@codeowners_key, :unset))

  defp codeowners_leaks(expected) when expected in [:unset, nil], do: []

  defp codeowners_leaks(expected) do
    case codeowners_state() do
      nil -> []
      ^expected -> []
      actual -> ["Aiur.GitHub.CodeOwners changed from #{inspect(expected)} to #{inspect(actual)}"]
    end
  end

  defp restore_codeowners(expected) do
    case expected do
      %{allowlist: allowlist, codeowners: codeowners} ->
        restore_codeowners_if_running(allowlist, codeowners)

      _ ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp restore_codeowners_if_running(allowlist, codeowners) do
    case Process.whereis(Aiur.GitHub.CodeOwners) do
      pid when is_pid(pid) ->
        :sys.replace_state(pid, fn state ->
          %{state | allowlist: MapSet.new(allowlist), codeowners: MapSet.new(codeowners)}
        end)

      nil ->
        :ok
    end
  end

  defp codeowners_state do
    case Process.whereis(Aiur.GitHub.CodeOwners) do
      pid when is_pid(pid) ->
        %{
          allowlist: CodeOwners.snapshot(pid),
          codeowners: CodeOwners.codeowners_snapshot(pid)
        }

      nil ->
        nil
    end
  catch
    :exit, _reason -> nil
  end

  defp decision_store_leaks do
    case Aiur.DecisionStore.health() do
      {:unavailable, {:path_unresolved, reason}} -> ["Aiur.DecisionStore retained unavailable path state: #{inspect(reason)}"]
      _ -> []
    end
  catch
    :exit, reason -> ["Aiur.DecisionStore health could not be read: #{inspect(reason)}"]
  end

  defp recover_decision_store([]), do: :ok

  defp recover_decision_store(_leaks) do
    with :ok <- RuntimeChildren.ensure_aiur_supervisor_running(),
         :ok <- terminate_decision_store(),
         {:ok, _pid} <- Supervisor.restart_child(Aiur.Supervisor, Aiur.DecisionStore),
         :writable <- Aiur.DecisionStore.health() do
      :ok
    else
      _ -> :error
    end
  catch
    :exit, _reason -> :error
  end

  defp recovery_errors(:ok), do: []
  defp recovery_errors(:error), do: ["Aiur.DecisionStore recovery failed"]

  defp terminate_decision_store do
    case Process.whereis(Aiur.DecisionStore) do
      pid when is_pid(pid) -> Supervisor.terminate_child(Aiur.Supervisor, Aiur.DecisionStore)
      nil -> :ok
    end
  end

  defp restore_app_env(key, :error), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:aiur, key, value)

  defp restore_instance_key(nil), do: System.delete_env("AIUR_INSTANCE_KEY")
  defp restore_instance_key(value), do: System.put_env("AIUR_INSTANCE_KEY", value)

  # nil when the name belongs to the supervised child, which is what every test expects to find.
  defp leak do
    case {Process.whereis(Aiur.Orchestrator), OrchestratorChild.supervised_pid()} do
      {nil, _child} -> "down"
      {pid, pid} -> nil
      {pid, _child} -> "held by a stand-in #{inspect(pid)}"
    end
  end

  defp restore("down"), do: RuntimeChildren.ensure_orchestrator_running()

  defp restore(_stand_in) do
    Process.unregister(Aiur.Orchestrator)
    RuntimeChildren.ensure_orchestrator_running()
  rescue
    # The stand-in exited and freed the name meanwhile.
    ArgumentError -> RuntimeChildren.ensure_orchestrator_running()
  end

  defp record_leak(name, leak),
    do: :persistent_term.put(@suite_leaks_key, :persistent_term.get(@suite_leaks_key, []) ++ ["#{name || "unknown"} (#{leak})"])

  defp record_runtime_child_leak(name, leak),
    do: :persistent_term.put(@runtime_child_leaks_key, :persistent_term.get(@runtime_child_leaks_key, []) ++ ["#{name || "unknown"} (#{leak})"])

  defp last_finished do
    GenServer.call(__MODULE__, :last_finished, 1_000)
  catch
    :exit, _reason -> nil
  end

  defp test_name(context), do: "#{inspect(context[:module])}: #{context[:test]}"
end
