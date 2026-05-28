defmodule Aiur.Sandbox.EventFlowDemo do
  @moduledoc false
  # Baseline scaffold for the 3-ticket event-flow sandbox. Agents on
  # the test tickets flesh this out during the manual --test workflow;
  # `aiur --test` restores this file to HEAD before each fresh run.

  @spec function_a() :: 42
  def function_a, do: 42

  @spec function_b() :: integer()
  def function_b do
    function_a() + 1
  end
end
