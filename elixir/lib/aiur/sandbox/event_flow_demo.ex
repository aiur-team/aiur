defmodule Aiur.Sandbox.EventFlowDemo do
  @moduledoc false

  @spec function_a() :: 42
  def function_a, do: 42

  @spec function_b() :: integer()
  def function_b do
    function_a() + 1
  end

  @spec function_c() :: integer()
  def function_c do
    result = function_b()
    result * result
  end
end
