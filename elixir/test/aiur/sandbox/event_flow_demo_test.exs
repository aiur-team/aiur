defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  test "function_a returns the ticket 99 value" do
    assert EventFlowDemo.function_a() == 42
  end
end
