defmodule Aiur.DecisionDispatchTestSupport do
  def callback(test_pid) do
    fn correlation, result -> send(test_pid, {:terminal, correlation, result}) end
  end

  def blocking_job(test_pid, label) do
    fn ->
      send(test_pid, {:started, label, self()})
      receive do: (:release -> :ok)
    end
  end

  def unique_name(test_module, suffix) do
    Module.concat(test_module, "#{suffix}#{System.unique_integer([:positive])}")
  end
end
