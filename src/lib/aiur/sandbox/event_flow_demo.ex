defmodule Aiur.Sandbox.EventFlowDemo do
  @moduledoc false
  # Baseline scaffold for the 3-ticket event-flow sandbox. Agents on
  # the test tickets flesh this out during the manual --test workflow;
  # `aiur --test` restores this file to HEAD before each fresh run.

  # Sandbox ticket #1: return 42 as a bare integer literal (operator
  # delegated judgement → option A). Ticket #2 depends on this push.
  def function_a, do: 42
end
