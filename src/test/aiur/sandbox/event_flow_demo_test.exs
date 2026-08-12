defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  test "function_a/0 returns the integer 42" do
    assert EventFlowDemo.function_a() == 42
  end
end
