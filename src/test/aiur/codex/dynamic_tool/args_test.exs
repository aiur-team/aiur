defmodule Aiur.Codex.DynamicTool.ArgsTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.DynamicTool.Args

  describe "string/3" do
    test "trims whitespace and returns the trimmed value" do
      assert {:ok, "hello"} = Args.string(%{"key" => "  hello  "}, "key", :missing)
    end

    test "rejects blank strings with the given error reason" do
      assert {:error, :missing_key} = Args.string(%{"key" => "   "}, "key", :missing_key)
    end

    test "rejects missing key with the given error reason" do
      assert {:error, :not_found} = Args.string(%{}, "key", :not_found)
    end

    test "accepts atom-key variant" do
      assert {:ok, "value"} = Args.string(%{key: "value"}, "key", :missing)
    end

    test "rejects non-string values" do
      assert {:error, :bad} = Args.string(%{"key" => 123}, "key", :bad)
    end
  end

  describe "alert_string/3" do
    test "reads name key (string or atom)" do
      assert {:ok, "phase.work.start"} =
               Args.alert_string(%{"name" => "phase.work.start"}, "name", :missing)

      assert {:ok, "phase.work.start"} =
               Args.alert_string(%{name: "phase.work.start"}, "name", :missing)
    end

    test "reads message key" do
      assert {:ok, "msg"} = Args.alert_string(%{"message" => "msg"}, "message", :missing)
    end

    test "reads reason key" do
      assert {:ok, "reason text"} =
               Args.alert_string(%{"reason" => "reason text"}, "reason", :missing)
    end

    test "rejects blank value" do
      assert {:error, :miss} = Args.alert_string(%{"name" => ""}, "name", :miss)
    end

    test "rejects missing key" do
      assert {:error, :miss} = Args.alert_string(%{}, "name", :miss)
    end
  end

  describe "emit_alert_value/2" do
    test "returns nil for absent key" do
      assert nil == Args.emit_alert_value(%{}, "name")
      assert nil == Args.emit_alert_value(%{}, "message")
      assert nil == Args.emit_alert_value(%{}, "reason")
    end

    test "returns value for string-key name" do
      assert "foo" == Args.emit_alert_value(%{"name" => "foo"}, "name")
    end

    test "returns value for atom-key name" do
      assert "foo" == Args.emit_alert_value(%{name: "foo"}, "name")
    end
  end

  describe "has_key?/2" do
    test "true for string key present" do
      assert Args.has_key?(%{"k" => 1}, "k")
    end

    test "true for atom key present" do
      assert Args.has_key?(%{k: 1}, "k")
    end

    test "false when neither key present" do
      refute Args.has_key?(%{}, "k")
    end
  end

  describe "boolean/3" do
    test "accepts true" do
      assert {:ok, true} = Args.boolean(%{"flag" => true}, "flag", :missing)
    end

    test "accepts false" do
      assert {:ok, false} = Args.boolean(%{"flag" => false}, "flag", :missing)
    end

    test "rejects a non-boolean present value" do
      assert {:error, :bad} = Args.boolean(%{"flag" => "true"}, "flag", :bad)
    end

    test "rejects missing key" do
      assert {:error, :miss} = Args.boolean(%{}, "flag", :miss)
    end

    test "accepts atom-key boolean" do
      assert {:ok, true} = Args.boolean(%{flag: true}, "flag", :missing)
    end
  end
end
