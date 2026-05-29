defmodule Aiur.Sandbox.EventFlowDemo do
  @moduledoc false
  # Baseline scaffold for the 3-ticket event-flow sandbox. Agents on
  # the test tickets flesh this out during the manual --test workflow;
  # `aiur --test` restores this file to HEAD before each fresh run.

  # Temporary #99 stub so #100 can compile until the real upstream
  # branch lands and is integrated.
  def function_a do
    42
  end

  def function_b do
    function_a() + 1
  end
end
