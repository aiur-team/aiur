defmodule Aiur.Codex.DynamicTool.ErrorsTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.DynamicTool.Errors

  describe "payload/1 — linear tool family" do
    test ":missing_query renders correct message" do
      assert %{"error" => %{"message" => msg}} = Errors.payload(:missing_query)
      assert msg =~ "non-empty `query` string"
    end

    test "{:linear_api_status, 500} includes status code" do
      assert %{"error" => %{"message" => msg, "status" => 500}} =
               Errors.payload({:linear_api_status, 500})

      assert msg =~ "500"
    end

    test ":invalid_variables renders correct message" do
      assert %{"error" => %{"message" => msg}} = Errors.payload(:invalid_variables)
      assert msg =~ "variables"
    end
  end

  describe "payload/1 — alert tool family" do
    test ":invalid_alert_arguments renders correct message" do
      assert %{"error" => %{"message" => msg}} = Errors.payload(:invalid_alert_arguments)
      assert msg =~ "emit_alert"
    end

    test ":missing_alert_name renders correct message" do
      assert %{"error" => %{"message" => msg}} = Errors.payload(:missing_alert_name)
      assert msg =~ "name"
    end
  end

  describe "payload/1 — event tool family" do
    test ":event_name_not_in_allowlist renders agent vocabulary message with examples" do
      result = Errors.payload(:event_name_not_in_allowlist)
      assert result["error"]["message"] =~ "agent vocabulary"
      assert is_list(result["error"]["examples"])
    end
  end

  describe "payload/1 — subscription family" do
    test ":missing_topic_pattern renders correct message" do
      assert %{"error" => %{"message" => msg}} = Errors.payload(:missing_topic_pattern)
      assert msg =~ "topic_pattern"
    end

    test ":agent_subscription_scope_forbidden renders the allowed boundary" do
      assert %{"error" => %{"message" => msg}} = Errors.payload(:agent_subscription_scope_forbidden)
      assert msg =~ "literal ticket"
      assert msg =~ "ticket.42.#"
    end
  end

  describe "payload/1 — blocker family" do
    test ":invalid_issue_number renders correct message" do
      assert %{"error" => %{"message" => msg}} = Errors.payload(:invalid_issue_number)
      assert msg =~ "positive integer"
    end

    test ":cycle_detected renders correct message" do
      assert %{"error" => %{"message" => msg}} = Errors.payload(:cycle_detected)
      assert msg =~ "cycle"
    end
  end

  describe "payload/1 — catch-all" do
    test "unknown atom renders the Aiur catch-all message with inspected reason" do
      result = Errors.payload(:some_unknown_error)
      assert result["error"]["message"] == "Aiur tool execution failed."
      assert result["error"]["reason"] == ":some_unknown_error"
    end

    test "unknown tuple renders the Aiur catch-all message" do
      result = Errors.payload({:something_weird, "detail"})
      assert result["error"]["message"] == "Aiur tool execution failed."
    end
  end
end
