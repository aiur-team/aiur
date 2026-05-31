defmodule Aiur.Sandbox.EventFlowDemo do
  @moduledoc false
  # Baseline scaffold for the 3-ticket event-flow sandbox. Agents on
  # the test tickets flesh this out during the manual --test workflow;
  # `aiur --test` restores this file to HEAD before each fresh run.

  # function_a/0 and function_b/0 are stubs matching the agreed
  # contracts from #99 and #100 — added here so function_c/0 compiles
  # and runs while those upstream tickets are still in flight. To be
  # replaced by the real implementations on merge.
  @spec function_a() :: 42
  def function_a, do: 42

  @spec function_b() :: 43
  def function_b, do: function_a() + 1

  @spec function_c() :: 1849
  def function_c, do: function_b() * function_b()
end
