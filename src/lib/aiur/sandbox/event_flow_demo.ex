defmodule Aiur.Sandbox.EventFlowDemo do
  @moduledoc false
  # Baseline scaffold for the 3-ticket event-flow sandbox. Agents on
  # the test tickets flesh this out during the manual --test workflow;
  # `aiur --test` restores this file to HEAD before each fresh run.

  # function_a/0 is the real implementation integrated from aiur/99
  # (e5897ce). function_b/0 is a stub matching the agreed contract
  # from #100 — kept local so function_c/0 compiles and runs while
  # that ticket is in flight; swapped on its branch.push.
  @spec function_a() :: integer()
  def function_a, do: 42

  @spec function_b() :: integer()
  def function_b, do: function_a() + 1

  @spec function_c() :: integer()
  def function_c, do: function_b() * function_b()
end
