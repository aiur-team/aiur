defmodule Aiur.Codex.DynamicTool.EmitEventTest do
  use ExUnit.Case, async: false

  alias Aiur.Codex.DynamicTool.EmitEvent

  setup do
    EmitEvent.reset_turn_quotas()
    :ok
  end

  defp publisher do
    test_pid = self()

    fn name, message, payload ->
      send(test_pid, {:published, name, message, payload})
      {:ok, %{}}
    end
  end

  describe "allowlist" do
    test "accepts bare progress" do
      response =
        EmitEvent.execute(
          "emit_event",
          %{"name" => "progress", "message" => "30%", "payload" => %{"percent" => 30}},
          event_publisher: publisher()
        )

      assert response["success"] == true
      assert_received {:published, "progress", "30%", %{"percent" => 30}}
    end

    test "accepts progress.<slug>" do
      response =
        EmitEvent.execute(
          "emit_event",
          %{"name" => "progress.brainstorm-end", "message" => "done"},
          event_publisher: publisher()
        )

      assert response["success"] == true
    end

    test "accepts decision.<slug>" do
      response =
        EmitEvent.execute(
          "emit_event",
          %{"name" => "decision.use-json", "message" => "decided"},
          event_publisher: publisher()
        )

      assert response["success"] == true
    end

    test "accepts custom.<slug>" do
      response =
        EmitEvent.execute(
          "emit_event",
          %{"name" => "custom.heartbeat", "message" => "ping"},
          event_publisher: publisher()
        )

      assert response["success"] == true
    end

    test "accepts blocked" do
      response =
        EmitEvent.execute(
          "emit_event",
          %{"name" => "blocked", "message" => "blocked on 42"},
          event_publisher: publisher()
        )

      assert response["success"] == true
    end

    test "accepts unblocked" do
      response =
        EmitEvent.execute(
          "emit_event",
          %{"name" => "unblocked", "message" => "unblocked"},
          event_publisher: publisher()
        )

      assert response["success"] == true
    end

    test "accepts attention.resolved" do
      response =
        EmitEvent.execute(
          "emit_event",
          %{"name" => "attention.resolved", "message" => "resolved"},
          event_publisher: publisher()
        )

      assert response["success"] == true
    end

    test "accepts pause.request" do
      response =
        EmitEvent.execute(
          "emit_event",
          %{"name" => "pause.request", "message" => "pausing"},
          event_publisher: publisher()
        )

      assert response["success"] == true
    end

    test "rejects names outside the allowlist" do
      for name <- ["system.weird", "agent.done", "PROGRESS", "custom", "foobar"] do
        response =
          EmitEvent.execute(
            "emit_event",
            %{"name" => name, "message" => "test"},
            event_publisher: publisher()
          )

        assert response["success"] == false, "expected #{name} to be rejected"
        assert Jason.decode!(response["output"])["error"]["message"] =~ "agent vocabulary"
      end
    end
  end

  describe "payload defaults" do
    test "missing payload field defaults to empty map" do
      EmitEvent.execute(
        "emit_event",
        %{"name" => "blocked", "message" => "x"},
        event_publisher: publisher()
      )

      assert_received {:published, "blocked", "x", %{}}
    end
  end

  describe "required field validation" do
    test "missing name returns error" do
      response =
        EmitEvent.execute(
          "emit_event",
          %{"message" => "x"},
          event_publisher: publisher()
        )

      assert response["success"] == false
    end

    test "missing message returns error" do
      response =
        EmitEvent.execute(
          "emit_event",
          %{"name" => "blocked"},
          event_publisher: publisher()
        )

      assert response["success"] == false
    end

    test "missing publisher returns unavailable error" do
      response =
        EmitEvent.execute(
          "emit_event",
          %{"name" => "blocked", "message" => "x"},
          []
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "unavailable"
    end
  end

  describe "bare-progress per-turn cap" do
    test "2 progress emits per turn succeed" do
      opts = [event_publisher: publisher()]

      assert %{"success" => true} =
               EmitEvent.execute("emit_event", %{"name" => "progress", "message" => "30%", "payload" => %{"percent" => 30}}, opts)

      assert %{"success" => true} =
               EmitEvent.execute("emit_event", %{"name" => "progress", "message" => "60%", "payload" => %{"percent" => 60}}, opts)
    end

    test "3rd progress emit in same turn is rejected" do
      opts = [event_publisher: publisher()]

      EmitEvent.execute("emit_event", %{"name" => "progress", "message" => "30%", "payload" => %{"percent" => 30}}, opts)
      EmitEvent.execute("emit_event", %{"name" => "progress", "message" => "60%", "payload" => %{"percent" => 60}}, opts)

      response =
        EmitEvent.execute("emit_event", %{"name" => "progress", "message" => "100%", "payload" => %{"percent" => 100}}, opts)

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "per-turn `progress` cap"
    end

    test "reset_turn_quotas/0 restores the budget" do
      opts = [event_publisher: publisher()]

      EmitEvent.execute("emit_event", %{"name" => "progress", "message" => "30%", "payload" => %{"percent" => 30}}, opts)
      EmitEvent.execute("emit_event", %{"name" => "progress", "message" => "60%", "payload" => %{"percent" => 60}}, opts)

      assert :ok = EmitEvent.reset_turn_quotas()

      assert %{"success" => true} =
               EmitEvent.execute("emit_event", %{"name" => "progress", "message" => "80%", "payload" => %{"percent" => 80}}, opts)
    end

    test "progress.<slug> does not consume the bare-progress budget" do
      opts = [event_publisher: publisher()]

      EmitEvent.execute("emit_event", %{"name" => "progress", "message" => "30%", "payload" => %{"percent" => 30}}, opts)
      EmitEvent.execute("emit_event", %{"name" => "progress", "message" => "60%", "payload" => %{"percent" => 60}}, opts)

      assert %{"success" => true} =
               EmitEvent.execute("emit_event", %{"name" => "progress.tests-green", "message" => "green"}, opts)
    end

    test "custom.* does not consume the bare-progress budget" do
      opts = [event_publisher: publisher()]

      EmitEvent.execute("emit_event", %{"name" => "progress", "message" => "30%", "payload" => %{"percent" => 30}}, opts)
      EmitEvent.execute("emit_event", %{"name" => "progress", "message" => "60%", "payload" => %{"percent" => 60}}, opts)

      assert %{"success" => true} =
               EmitEvent.execute("emit_event", %{"name" => "custom.heartbeat", "message" => "ping"}, opts)
    end
  end
end
