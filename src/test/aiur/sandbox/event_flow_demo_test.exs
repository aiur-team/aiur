defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  alias Aiur.Sandbox.EventFlowDemo

  # The sandbox scaffold is restored to HEAD before each `aiur --test` run, so
  # this guards the one contract the event-flow tickets actually depend on:
  # `function_a/0` returns the integer 42.
  test "function_a/0 returns the integer 42" do
    assert EventFlowDemo.function_a() === 42
  end
end
