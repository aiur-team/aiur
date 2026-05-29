defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  test "function_b/0 calls function_a/0 and adds one" do
    assert EventFlowDemo.function_b() == 43
  end

  test "function_c/0 squares function_b/0" do
    assert EventFlowDemo.function_c() == 1849
  end
end
