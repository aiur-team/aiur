defmodule Aiur.Config.AllowedContributorsParserTest do
  use ExUnit.Case, async: true

  alias Aiur.AllowedContributors.AllowList
  alias Aiur.Config.Schema.AllowedContributorsParser

  # Regression guard: config and file callers preserve the same validation.
  test "config parser and public delegate preserve valid and malformed input behavior" do
    cases = [
      {%{}, {:ok, %{users: %{}, orgs: %{}}}},
      {%{"users" => [1, 1], "orgs" => [%{"id" => 2, "login" => "acme"}]}, {:ok, %{users: %{1 => true}, orgs: %{2 => "acme"}}}},
      {nil, {:error, "must be a map with users and orgs; use {} to admit nobody"}},
      {%{"orgs" => [%{"id" => 2, "login" => "a"}, %{"id" => 2, "login" => "b"}]}, {:error, "invalid allow-list: {:line, 2, :conflicting_org}"}}
    ]

    for {input, expected} <- cases do
      assert AllowedContributorsParser.from_config(input) == expected
      assert AllowList.from_config(input) == expected
    end

    for input <- [%{"extra" => []}, %{"users" => [0]}, %{"users" => "1"}, %{"orgs" => [%{"id" => 1, "login" => "../bad"}]}] do
      expected = {:error, "must contain only users (positive int64 ids) and orgs (maps with positive int64 id and valid login)"}
      assert AllowedContributorsParser.from_config(input) == expected
      assert AllowList.from_config(input) == expected
    end
  end
end
