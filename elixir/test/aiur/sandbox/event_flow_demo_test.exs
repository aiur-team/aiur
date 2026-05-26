defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  describe "function_a/0" do
    test "returns 42" do
      assert Aiur.Sandbox.EventFlowDemo.function_a() == 42
    end
  end
end
