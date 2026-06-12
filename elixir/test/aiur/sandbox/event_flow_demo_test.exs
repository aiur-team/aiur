defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  test "function_a/0 returns the event-flow seed value" do
    assert EventFlowDemo.function_a() == 42
  end

  test "function_b/0 calls function_a/0 and adds one" do
    assert EventFlowDemo.function_b() == 43
  end

  test "function_c/0 squares function_b/0" do
    b = EventFlowDemo.function_b()
    assert EventFlowDemo.function_c() == b * b
  end
end
