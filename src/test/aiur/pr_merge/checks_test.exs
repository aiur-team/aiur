defmodule Aiur.PrMerge.ChecksTest do
  use ExUnit.Case, async: true
  alias Aiur.PrMerge.Checks

  test "legacy errors and failed template names block while neutral checks pass" do
    checks = [
      %{"__typename" => "StatusContext", "context" => "legacy", "state" => "ERROR"},
      %{"__typename" => "CheckRun", "name" => "${{ matrix.shard }}", "status" => "COMPLETED", "conclusion" => "FAILURE"},
      %{"__typename" => "CheckRun", "name" => "neutral", "status" => "COMPLETED", "conclusion" => "NEUTRAL"},
      %{"__typename" => "CheckRun", "name" => "${{ placeholder }}", "status" => "IN_PROGRESS"},
      %{"__typename" => "StatusContext", "context" => "waiting", "state" => "PENDING"}
    ]

    assert Checks.classify(checks) == %{failed: ["legacy", "${{ matrix.shard }}"], passed: ["neutral"], pending: ["waiting"]}
  end

  test "app-qualified success can satisfy only that app's required context" do
    check = %{"__typename" => "CheckRun", "name" => "lint", "status" => "COMPLETED", "conclusion" => "SUCCESS", "checkSuite" => %{"app" => %{"databaseId" => 123}}}
    assert Checks.classify([check]).passed == ["lint", "lint (app 123)"]
    refute "lint (app 456)" in Checks.classify([check]).passed
  end
end
