defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  test "function_a/0 returns the sandbox sentinel value" do
    assert EventFlowDemo.function_a() == 42
  end

  test "function_b/0 calls function_a/0 and adds one" do
    assert EventFlowDemo.function_b() == 43
  end
end