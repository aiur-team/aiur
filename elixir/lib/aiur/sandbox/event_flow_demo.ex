defmodule Aiur.Sandbox.EventFlowDemo do
  @moduledoc false
  # Baseline scaffold for the 3-ticket event-flow sandbox. Agents on
  # the test tickets flesh this out during the manual --test workflow;
  # `aiur --test` restores this file to HEAD before each fresh run.

  # Temporary unblocker for #100 while #99 owns the real function_a/0 change.
  # Remove this stub when integrating the canonical implementation from #99.
  @spec function_a() :: integer()
  def function_a, do: 42

  @spec function_b() :: integer()
  def function_b do
    function_a() + 1
  end
end
