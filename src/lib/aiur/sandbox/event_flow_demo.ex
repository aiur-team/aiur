defmodule Aiur.Sandbox.EventFlowDemo do
  @moduledoc false
  # Baseline scaffold for the 3-ticket event-flow sandbox. Agents on
  # the test tickets flesh this out during the manual --test workflow;
  # `aiur --test` restores this file to HEAD before each fresh run.

  @doc "Sandbox seed for event-flow ticket #1."
  @spec function_a() :: integer()
  def function_a, do: 42
end
