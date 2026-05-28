defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  test "function_b calls function_a and adds one" do
    assert EventFlowDemo.function_b() == EventFlowDemo.function_a() + 1
  end
end
