defmodule Aiur.Sandbox.EventFlowDemo do
  @moduledoc false
  @spec function_a() :: integer()
  def function_a, do: 42

  @spec function_b() :: integer()
  def function_b, do: function_a() + 1

  @spec function_c() :: integer()
  def function_c do
    x = function_b()
    x * x
  end
end
