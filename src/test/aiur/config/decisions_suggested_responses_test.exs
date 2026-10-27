defmodule Aiur.Config.DecisionsSuggestedResponsesTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema

  test "suggested response enforcement defaults off and accepts explicit booleans" do
    for {attrs, expected} <- [
          {%{}, false},
          {%{"decisions" => %{}}, false},
          {%{"decisions" => %{"require_suggested_responses" => true}}, true},
          {%{"decisions" => %{"require_suggested_responses" => false}}, false}
        ] do
      assert {:ok, settings} = Schema.parse(attrs)
      assert settings.decisions.require_suggested_responses == expected
    end
  end

  test "invalid enforcement type is rejected" do
    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"decisions" => %{"require_suggested_responses" => "invalid"}})
    assert message =~ "decisions.require_suggested_responses"
  end
end
