defmodule Aiur.Sandbox.EventFlowDemo do
  @moduledoc false

  @spec function_a() :: integer()
  def function_a do
    42
  end

  @spec function_b() :: integer()
  def function_b do
    function_a() + 1
  end

  @spec function_c() :: integer()
  def function_c do
    function_b() * function_b()
  end
end
