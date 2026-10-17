defmodule Aiur.AgentControlCLIUsageTest do
  use ExUnit.Case, async: true

  # Future compatibility guard: preserve all existing usage and account arities.
  test "accounting delegates retain their public arities" do
    exported = Aiur.AgentControlCLI.__info__(:functions)

    for signature <- [usage: 0, usage: 1, usage: 2, accounts: 1, accounts: 2, usage_bar: 1] do
      assert signature in exported
    end
  end
end
