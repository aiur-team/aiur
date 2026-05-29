defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  test "function_a/0 returns the sandbox sentinel value" do
    assert EventFlowDemo.function_a() == 42
  end

  test "function_b calls function_a and adds one" do
    assert EventFlowDemo.function_b() == 43
  end

  test "function_c squares function_b" do
    assert EventFlowDemo.function_c() == 1849
  end
end
