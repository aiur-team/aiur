defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  test "function_a/0 returns 42" do
    assert EventFlowDemo.function_a() == 42
  end

  describe "function_b/0" do
    test "adds one to function_a/0" do
      assert EventFlowDemo.function_b() == EventFlowDemo.function_a() + 1
    end
  end

  describe "function_c/0" do
    test "squares function_b/0" do
      result = EventFlowDemo.function_b()

      assert EventFlowDemo.function_c() == result * result
    end
  end
end
