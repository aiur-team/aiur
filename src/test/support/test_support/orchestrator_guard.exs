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

  alias Aiur.TestSupport.OrchestratorChild

  alias Aiur.TestSupport.RuntimeChildren

  # persistent_term, not GenServer state: after_suite callbacks run once formatters have stopped.
  @suite_leaks_key {__MODULE__, :suite_leaks}
  @last_finished_key {__MODULE__, :last_finished}

  @impl true
  def init(_opts) do
    Process.register(self(), __MODULE__)
    :persistent_term.put(@suite_leaks_key, [])
    :persistent_term.put(@last_finished_key, nil)
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
  def handle_call(:last_finished, _from, last), do: {:reply, last, last}

  @doc "Fails the suite when a plain ExUnit case leaked the orchestrator. Runs after the formatters stop."
  @spec verify_suite!() :: :ok
  def verify_suite! do
    if leak = leak(), do: record_leak(:persistent_term.get(@last_finished_key, nil), leak)

    case :persistent_term.get(@suite_leaks_key, []) do
      [] -> :ok
      leaks -> raise "plain ExUnit tests broke Aiur.Orchestrator: #{Enum.join(leaks, ", ")}"
    end
  end

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

    if leak = leak() do
      restored = restore(leak)

      raise "#{test_name(context)} left Aiur.Orchestrator #{leak} (restore: #{inspect(restored)}). " <>
              "Restore it in on_exit with Aiur.TestSupport.ensure_orchestrator_running/0 or await_supervised_restart/3."
    end

    :ok
  end

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

  defp last_finished do
    GenServer.call(__MODULE__, :last_finished, 1_000)
  catch
    :exit, _reason -> nil
  end

  defp test_name(context), do: "#{inspect(context[:module])}: #{context[:test]}"
end
