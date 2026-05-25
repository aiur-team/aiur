defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  test "function_b returns one more than function_a" do
    assert EventFlowDemo.function_b() == EventFlowDemo.function_a() + 1
  end

  test "function_c returns function_b squared" do
    assert EventFlowDemo.function_c() == EventFlowDemo.function_b() * EventFlowDemo.function_b()
  end
end
