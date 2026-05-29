defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  test "function_b/0 calls function_a/0 and adds one" do
    assert EventFlowDemo.function_b() == EventFlowDemo.function_a() + 1
  end
end
