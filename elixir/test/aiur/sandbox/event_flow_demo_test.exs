defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  describe "function_b/0" do
    test "adds one to function_a/0" do
      assert EventFlowDemo.function_b() == EventFlowDemo.function_a() + 1
    end
  end
end
