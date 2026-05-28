defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  test "function_a/0 returns 42" do
    assert EventFlowDemo.function_a() == 42
  end

  test "function_b/0 adds 1 to function_a/0" do
    assert EventFlowDemo.function_b() == 43
  end
end
