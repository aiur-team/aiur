defmodule Aiur.Sandbox.EventFlowDemo do
  @moduledoc false
  # Baseline scaffold for the 3-ticket event-flow sandbox. Agents on
  # the test tickets flesh this out during the manual --test workflow;
  # `aiur --test` restores this file to HEAD before each fresh run.

  # Sandbox ticket #99 (event-flow test): returns the integer 42.
  def function_a, do: 42
end
