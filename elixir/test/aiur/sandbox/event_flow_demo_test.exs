defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  test "function_a returns the event-flow sentinel value" do
    assert Aiur.Sandbox.EventFlowDemo.function_a() == 42
  end
end
