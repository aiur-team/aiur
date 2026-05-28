defmodule Aiur.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  test "function_b calls function_a and adds one" do
    assert EventFlowDemo.function_b() == 43
  end
end
