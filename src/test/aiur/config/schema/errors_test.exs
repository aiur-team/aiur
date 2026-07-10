defmodule Aiur.Config.Schema.ErrorsTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema.Errors

  describe "translate_error/1" do
    test "interpolates %{key} placeholders" do
      assert Errors.translate_error({"must be greater than %{number}", [number: 0]}) ==
               "must be greater than 0"
    end

    test "converts atom values to strings in placeholders" do
      assert Errors.translate_error({"is %{type}", [type: :integer]}) == "is integer"
    end

    test "converts non-atom values with inspect" do
      assert Errors.translate_error({"got %{val}", [val: [1, 2]]}) == "got [1, 2]"
    end

    test "leaves message unchanged when no placeholders match" do
      assert Errors.translate_error({"is invalid", []}) == "is invalid"
    end
  end

  describe "error_value_to_string/1" do
    test "converts atoms to string" do
      assert Errors.error_value_to_string(:integer) == "integer"
    end

    test "inspects non-atom values" do
      assert Errors.error_value_to_string(42) == "42"
      assert Errors.error_value_to_string([1, 2]) == "[1, 2]"
    end
  end

  describe "flatten_errors/2" do
    test "flattens a single-level map to prefixed strings" do
      errors = %{name: ["can't be blank"]}
      assert Errors.flatten_errors(errors) == ["name can't be blank"]
    end

    test "flattens nested maps to dotted-path prefixed strings" do
      errors = %{agent: %{codex: %{command: ["can't be blank"]}}}
      assert Errors.flatten_errors(errors) == ["agent.codex.command can't be blank"]
    end

    test "flattens multiple errors at the same level" do
      errors = %{field: ["error one", "error two"]}
      assert Errors.flatten_errors(errors) == ["field error one", "field error two"]
    end

    test "handles a prefix parameter" do
      errors = %{field: ["is invalid"]}
      assert Errors.flatten_errors(errors, "parent") == ["parent.field is invalid"]
    end
  end

  describe "format_errors/1 (via Schema.parse)" do
    test "produces dotted-path error strings for nested changesets" do
      alias Aiur.Config.Schema

      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"polling" => %{"interval_seconds" => -1}})

      assert message =~ "polling.interval_seconds"
      assert message =~ "must be greater than"
    end

    test "comma-joins multiple errors" do
      alias Aiur.Config.Schema

      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{
                 "polling" => %{"interval_seconds" => -1},
                 "max_vertical_panes" => -1
               })

      parts = String.split(message, ", ")
      assert length(parts) >= 2
    end
  end
end
