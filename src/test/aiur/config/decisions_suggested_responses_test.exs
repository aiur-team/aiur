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

  test "option media enforcement defaults off and rejects a non-boolean" do
    assert {:ok, settings} = Schema.parse(%{})
    refute settings.decisions.require_option_media
    assert {:ok, settings} = Schema.parse(%{"decisions" => %{"require_option_media" => true}})
    assert settings.decisions.require_option_media
    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"decisions" => %{"require_option_media" => "yes"}})
    assert message =~ "decisions.require_option_media"
  end
end
