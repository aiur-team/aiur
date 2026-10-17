defmodule Aiur.TestSupport.OrchestratorGuard do
  @moduledoc """
  Names the test that leaves the shared `Aiur.Orchestrator` down (#4909).

  It is also an ExUnit formatter that remembers the last finished test of any
  case template, so the shared setup can say who ran before it had to restart
  the orchestrator. The shared teardown fails a sync test that ends with the
  orchestrator down, so the leaking test fails itself instead of its
  successors. A sync plain `ExUnit.Case` test that ends with it down is
  recorded by the formatter and fails the run in `verify_suite!/0`.
  """
  use GenServer

  alias Aiur.TestSupport.RuntimeChildren

  @suite_leaks_key {__MODULE__, :suite_leaks}

  @impl true
  def init(_opts) do
    Process.register(self(), __MODULE__)
    # persistent_term, not GenServer state: after_suite callbacks run once formatters have stopped.
    :persistent_term.put(@suite_leaks_key, [])
    {:ok, nil}
  end

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{state: {tag, _}}}, last) when tag in [:excluded, :skipped, :invalid],
    do: {:noreply, last}

  def handle_cast({:test_finished, %ExUnit.Test{} = test}, _last) do
    name = "#{inspect(test.module)}: #{test.name}"

    # Aiur.TestSupport tests are restored by their teardown first, so only plain ExUnit.Case leaks land here.
    if not test.tags[:async] and is_nil(Process.whereis(Aiur.Orchestrator)) do
      IO.puts(:stderr, "#{name} left Aiur.Orchestrator down")
      :persistent_term.put(@suite_leaks_key, :persistent_term.get(@suite_leaks_key) ++ [name])
    end

    {:noreply, name}
  end

  def handle_cast(_event, last), do: {:noreply, last}

  @impl true
  def handle_call(:last_finished, _from, last), do: {:reply, last, last}

  @doc "Fails the suite when a synchronous plain ExUnit case leaked the orchestrator."
  @spec verify_suite!() :: :ok
  def verify_suite! do
    case :persistent_term.get(@suite_leaks_key, []) do
      [] -> :ok
      leaks -> raise "plain ExUnit tests left Aiur.Orchestrator down: #{Enum.join(leaks, ", ")}"
    end
  end

  @doc "Restores a missing orchestrator before a test and reports the test that ran before it."
  @spec ensure_running(map()) :: :ok | :error
  def ensure_running(context) do
    if is_nil(Process.whereis(Aiur.Orchestrator)) do
      IO.puts(:stderr, "Aiur.Orchestrator was down before #{test_name(context)}; last finished test: #{last_finished() || "unknown"}")
    end

    RuntimeChildren.ensure_orchestrator_running()
  end

  @doc """
  Raises when a sync test ends with the orchestrator down, after restoring it.
  Async tests are skipped: a concurrent sibling may hold the name briefly.
  """
  @spec verify_restored!(map()) :: :ok
  def verify_restored!(%{async: true}), do: :ok

  def verify_restored!(context) do
    # A call on the supervisor processes any child exit already in its mailbox.
    RuntimeChildren.supervisor_accepting_calls?(Process.whereis(Aiur.Supervisor), 1_000)

    if is_nil(Process.whereis(Aiur.Orchestrator)) do
      restored = RuntimeChildren.ensure_orchestrator_running()

      raise "#{test_name(context)} left Aiur.Orchestrator down (restore: #{inspect(restored)}). " <>
              "Restore it in on_exit with Aiur.TestSupport.ensure_orchestrator_running/0 or await_supervised_restart/3."
    end

    :ok
  end

  defp last_finished do
    GenServer.call(__MODULE__, :last_finished, 1_000)
  catch
    :exit, _reason -> nil
  end

  defp test_name(context), do: "#{inspect(context[:module])}: #{context[:test]}"
end
