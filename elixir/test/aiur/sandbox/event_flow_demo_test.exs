defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  test "function_c/0 squares function_b/0" do
    value = EventFlowDemo.function_b()

    assert EventFlowDemo.function_c() == value * value
  end
end
