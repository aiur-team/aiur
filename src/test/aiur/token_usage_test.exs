defmodule Aiur.TokenUsageTest do
  use ExUnit.Case, async: true

  alias Aiur.TokenUsage

  describe "canonicalize/1" do
    test "normalizes snake/camel and atom/string token spellings" do
      assert TokenUsage.canonicalize(%{
               "completionTokens" => 20,
               prompt_tokens: "10",
               totalTokens: 30
             }) == %{input_tokens: 10, output_tokens: 20, total_tokens: 30}
    end

    test "zero-fills missing fields only when at least one token field exists" do
      assert TokenUsage.canonicalize(%{"inputTokens" => 7}) == %{
               input_tokens: 7,
               output_tokens: 0,
               total_tokens: 0
             }

      assert TokenUsage.canonicalize(%{"not_tokens" => 7}) == nil
    end

    test "returns nil for nil and non-map input" do
      assert TokenUsage.canonicalize(nil) == nil
      assert TokenUsage.canonicalize("usage") == nil
    end
  end

  describe "token_field?/1" do
    test "detects non-negative integer and numeric string token fields" do
      assert TokenUsage.token_field?(%{inputTokens: 1})
      assert TokenUsage.token_field?(%{"promptTokens" => " 2 "})
      refute TokenUsage.token_field?(%{"promptTokens" => "-2"})
      refute TokenUsage.token_field?(%{"other" => 2})
      refute TokenUsage.token_field?(:none)
    end
  end

  describe "format_counts/1" do
    test "formats present counts without canonical zero-fill" do
      assert TokenUsage.format_counts(%{
               "input_tokens" => 1_200,
               outputTokens: "34",
               total: 1_234
             }) == "in 1.2K, out 34, total 1.2K"

      assert TokenUsage.format_counts(%{input_tokens: 2}) == "in 2"
    end

    test "returns nil for empty and non-map usage" do
      assert TokenUsage.format_counts(%{}) == nil
      assert TokenUsage.format_counts(nil) == nil
    end
  end
end
