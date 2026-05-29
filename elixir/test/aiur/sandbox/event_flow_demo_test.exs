defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  test "function_a returns the upstream event-flow value" do
    assert EventFlowDemo.function_a() == 42
  end

  test "function_b adds one to function_a" do
    assert EventFlowDemo.function_b() == 43
  end
end
