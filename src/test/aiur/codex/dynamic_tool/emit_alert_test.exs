defmodule Aiur.Codex.DynamicTool.EmitAlertTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.DynamicTool.EmitAlert

  describe "execute/3" do
    test "5-arity emitter succeeds" do
      test_pid = self()

      response =
        EmitAlert.execute(
          "emit_alert",
          %{
            "name" => "phase.work.start",
            "message" => "Working",
            "reason" => "started",
            "needs_attention" => false
          },
          alert_emitter: fn name, message, reason, needs_attention, severity ->
            send(test_pid, {:emitted, name, message, reason, needs_attention, severity})
            :ok
          end
        )

      assert response["success"] == true
      assert_received {:emitted, "phase.work.start", "Working", "started", false, "info"}
    end

    test "legacy 2-arity emitter succeeds" do
      test_pid = self()

      response =
        EmitAlert.execute(
          "emit_alert",
          %{"name" => "phase.plan.start", "message" => "Planning"},
          alert_emitter: fn name, message ->
            send(test_pid, {:legacy, name, message})
            :ok
          end
        )

      assert response["success"] == true
      assert_received {:legacy, "phase.plan.start", "Planning"}
    end

    test "reason defaults to message when absent" do
      test_pid = self()

      EmitAlert.execute(
        "emit_alert",
        %{"name" => "phase.plan.start", "message" => "Planning"},
        alert_emitter: fn _name, _message, reason, _needs_attention, _severity ->
          send(test_pid, {:reason, reason})
          :ok
        end
      )

      assert_received {:reason, "Planning"}
    end

    test "needs_attention defaults to false when absent" do
      test_pid = self()

      EmitAlert.execute(
        "emit_alert",
        %{"name" => "phase.plan.start", "message" => "Planning"},
        alert_emitter: fn _name, _message, _reason, needs_attention, _severity ->
          send(test_pid, {:na, needs_attention})
          :ok
        end
      )

      assert_received {:na, false}
    end

    test "explicit severity is passed through" do
      test_pid = self()

      EmitAlert.execute(
        "emit_alert",
        %{
          "name" => "phase.work.start",
          "message" => "Working",
          "reason" => "reason",
          "needs_attention" => true,
          "severity" => "critical"
        },
        alert_emitter: fn _name, _message, _reason, _needs_attention, severity ->
          send(test_pid, {:sev, severity})
          :ok
        end
      )

      assert_received {:sev, "critical"}
    end

    test "needs_attention: true defaults severity to warning" do
      test_pid = self()

      EmitAlert.execute(
        "emit_alert",
        %{"name" => "phase.work.start", "message" => "Urgent", "needs_attention" => true},
        alert_emitter: fn _name, _message, _reason, _needs_attention, severity ->
          send(test_pid, {:sev, severity})
          :ok
        end
      )

      assert_received {:sev, "warning"}
    end

    test "needs_attention: false defaults severity to info" do
      test_pid = self()

      EmitAlert.execute(
        "emit_alert",
        %{"name" => "phase.work.start", "message" => "Normal", "needs_attention" => false},
        alert_emitter: fn _name, _message, _reason, _needs_attention, severity ->
          send(test_pid, {:sev, severity})
          :ok
        end
      )

      assert_received {:sev, "info"}
    end

    test "explicit non-boolean needs_attention returns error" do
      response =
        EmitAlert.execute(
          "emit_alert",
          %{
            "name" => "phase.work.start",
            "message" => "Working",
            "needs_attention" => "true"
          },
          alert_emitter: fn _n, _m, _r, _na, _sev -> :ok end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "must be true or false"
    end

    test "unavailable emitter returns alert_emitter_unavailable" do
      response =
        EmitAlert.execute(
          "emit_alert",
          %{"name" => "phase.work.start", "message" => "Working"},
          []
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "unavailable"
    end
  end
end
