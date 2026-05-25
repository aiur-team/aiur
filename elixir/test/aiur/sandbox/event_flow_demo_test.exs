defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  test "function_b returns one more than function_a" do
    assert EventFlowDemo.function_b() == EventFlowDemo.function_a() + 1
  end
end
