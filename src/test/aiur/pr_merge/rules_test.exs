defmodule Aiur.PrMerge.RulesTest do
  use ExUnit.Case, async: true
  alias Aiur.PrMerge.Rules

  defp api(rules, protection) do
    fn
      "get", "repos/o/r/rules/branches/integration", _ -> {:ok, rules}
      "get", "repos/o/r/branches/integration/protection", _ -> protection
    end
  end

  test "required checks preserve app identity and combine active and legacy rules" do
    rules = [%{"type" => "required_status_checks", "parameters" => %{"required_status_checks" => [%{"context" => "lint", "integration_id" => 123}]}}]
    protection = %{"required_status_checks" => %{"checks" => [%{"context" => "legacy", "app_id" => 456}, %{"context" => "lint", "app_id" => 123}]}}
    assert {:ok, %{required: ["lint (app 123)", "legacy (app 456)"], merge_queue: false}} = Rules.read(api(rules, {:ok, protection}), "o/r", "integration", %{})
  end

  test "legacy contexts and missing protection are supported without permission reads" do
    assert {:ok, %{required: ["legacy"], merge_queue: false}} = Rules.read(api([], {:ok, %{"required_status_checks" => %{"contexts" => ["legacy"]}}}), "o/r", "integration", %{})
    assert {:ok, %{required: [], merge_queue: false}} = Rules.read(api([], {:error, "GitHub 404: absent"}), "o/r", "integration", %{})
  end

  test "malformed legacy protection cannot silently discard required checks" do
    for protection <- [nil, %{"required_status_checks" => %{}}, %{"required_status_checks" => %{"checks" => [%{}]}}, %{"required_status_checks" => %{"contexts" => [nil]}}] do
      assert {:error, _} = Rules.read(api([], {:ok, protection}), "o/r", "integration", %{})
    end
  end

  test "required workflow rules refuse until their checks can be verified" do
    assert {:error, "required workflow rules are not supported; wait for GitHub CI"} = Rules.read(api([%{"type" => "workflows"}], {:ok, %{}}), "o/r", "integration", %{})
  end
end
