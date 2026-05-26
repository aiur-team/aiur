defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  test "function_a returns 42" do
    assert Aiur.Sandbox.EventFlowDemo.function_a() == 42
  end
end
