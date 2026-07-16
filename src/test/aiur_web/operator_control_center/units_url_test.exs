defmodule AiurWeb.OperatorControlCenter.UnitsURLTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AiurWeb.OperatorControlCenter.{UnitsPolicy, UnitsURL}

  test "canonical encoding orders the version, non-default scope, then conditions" do
    selection = %{scope: :all, conditions: MapSet.new([:paused, :active])}

    assert UnitsURL.encode(selection) == "v=1&scope=all&conditions=active%2Cpaused"
    assert UnitsURL.encode(UnitsURL.default_selection()) == "v=1"
  end

  test "decoding removes invalid values without creating an unrepresentable selection" do
    assert UnitsURL.decode(%{"v" => "1", "scope" => "not-a-scope", "conditions" => "alert,wat,paused,alert"}) ==
             %{scope: :live, conditions: MapSet.new([:alert, :paused])}

    assert UnitsURL.decode(%{"v" => "999", "scope" => "all", "conditions" => "alert"}) == UnitsURL.default_selection()
  end

  test "the named zero-result reset returns the URL defaults" do
    assert UnitsURL.zero_result_reset() == UnitsPolicy.default_selection()
    assert UnitsURL.encode(UnitsURL.zero_result_reset()) == "v=1"
  end

  property "valid URL selections round trip to their normalized policy state" do
    check all(
            scope <- member_of(UnitsPolicy.scopes()),
            conditions <- list_of(member_of(UnitsPolicy.conditions()), max_length: 6),
            max_runs: 30
          ) do
      selection = %{scope: scope, conditions: MapSet.new(conditions)}
      assert UnitsURL.encode(selection) |> UnitsURL.decode() == UnitsPolicy.normalize_selection(selection)
    end
  end
end
