defmodule Aiur.Sandbox.EventFlowDemo do
  @moduledoc """
  Sandbox module for cross-ticket event-flow verification.
  """

  @doc """
  Returns the event-flow ticket #1 sentinel value.
  """
  @spec function_a() :: 42
  def function_a, do: 42
end
