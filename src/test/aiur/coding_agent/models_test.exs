defmodule Aiur.CodingAgent.ModelsTest do
  use ExUnit.Case, async: true

  alias Aiur.CodingAgent.Models

  test "derives each family alias to its latest semantic version" do
    aliases =
      Models.aliases([
        "gpt-5.9-sol",
        "gpt-5.10-sol",
        "gpt-5.6-terra",
        "gpt-5.5-mini",
        "gpt-5.4-mini",
        "gpt-5.5",
        "gpt-5.4"
      ])

    assert aliases["sol"] == "gpt-5.10-sol"
    assert aliases["terra"] == "gpt-5.6-terra"
    assert aliases["mini"] == "gpt-5.5-mini"
    assert aliases["gpt"] == "gpt-5.5"
  end

  test "unparseable ids remain pins and concrete ids win alias collisions" do
    aliases = Models.aliases(["future-model", "gpt-5.6-sol", "sol"])

    refute Map.has_key?(aliases, "future")
    refute Map.has_key?(aliases, "sol")
  end
end
