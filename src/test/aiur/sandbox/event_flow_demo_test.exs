defmodule Aiur.Sandbox.EventFlowDemoTest do
  use Aiur.TestSupport

  alias Aiur.Sandbox.EventFlowDemo

  test "function_a returns 42" do
    assert EventFlowDemo.function_a() == 42
  end
end
