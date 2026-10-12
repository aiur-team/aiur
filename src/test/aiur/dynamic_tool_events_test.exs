defmodule Aiur.Codex.DynamicToolEventsTest do
  use Aiur.TestSupport
  alias Aiur.Codex.DynamicTool

  describe "emit_event" do
    test "publishes a progress.<slug> event for a valid name" do
      published = self()

      stub_publisher = fn name, message, payload ->
        send(published, {:published, name, message, payload})
        {:ok, %{"id" => 12_345, "topic" => "ticket.42.agent.progress.brainstorm-end"}}
      end

      response =
        DynamicTool.execute(
          "emit_event",
          %{"name" => "progress.brainstorm-end", "message" => "Done"},
          event_publisher: stub_publisher
        )

      assert response["success"] == true
      assert Jason.decode!(response["output"])["name"] == "progress.brainstorm-end"
      assert_receive {:published, "progress.brainstorm-end", "Done", %{}}, 200
    end

    test "passes through optional payload" do
      published = self()

      stub = fn _, _, payload ->
        send(published, {:payload, payload})
        {:ok, %{}}
      end

      DynamicTool.execute(
        "emit_event",
        %{"name" => "blocked", "message" => "x", "payload" => %{"blocking_issue" => 80}},
        event_publisher: stub
      )

      assert_receive {:payload, %{"blocking_issue" => 80}}, 200
    end

    test "rejects names outside the agent allowlist" do
      stub = fn _, _, _ -> {:ok, %{}} end

      response =
        DynamicTool.execute(
          "emit_event",
          %{"name" => "system.weird.thing", "message" => "no"},
          event_publisher: stub
        )

      assert response["success"] == false

      assert Jason.decode!(response["output"])["error"]["message"] =~ "agent vocabulary"
    end

    test "accepts every documented exact-match name" do
      stub = fn _, _, _ -> {:ok, %{}} end

      for name <- ["blocked", "unblocked", "attention.resolved", "pause.request"] do
        assert %{"success" => true} =
                 DynamicTool.execute(
                   "emit_event",
                   %{"name" => name, "message" => "ok"},
                   event_publisher: stub
                 )
      end
    end

    test "requires name and message" do
      stub = fn _, _, _ -> {:ok, %{}} end

      r1 = DynamicTool.execute("emit_event", %{"message" => "x"}, event_publisher: stub)
      r2 = DynamicTool.execute("emit_event", %{"name" => "blocked"}, event_publisher: stub)

      assert r1["success"] == false
      assert r2["success"] == false
    end

    test "returns error when publisher is missing from opts" do
      response = DynamicTool.execute("emit_event", %{"name" => "blocked", "message" => "x"})
      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "unavailable"
    end

    test "tool_specs advertises emit_event" do
      assert Enum.any?(DynamicTool.tool_specs(), fn spec ->
               spec["name"] == "emit_event" and
                 spec["description"] =~ "other agents/the Executor" and
                 spec["description"] =~ "Executor-facing audible alerts"
             end)
    end
  end

  describe "aiur_subscribe / aiur_unsubscribe" do
    test "subscribe invokes injected closure with the topic pattern" do
      test_pid = self()

      stub = fn pattern ->
        send(test_pid, {:subscribed, pattern})
        :ok
      end

      response =
        DynamicTool.execute(
          "aiur_subscribe",
          %{"topic_pattern" => "ticket.42.#"},
          subscriber: stub
        )

      assert response["success"] == true
      assert_receive {:subscribed, "ticket.42.#"}, 200
    end

    test "unsubscribe invokes injected closure" do
      test_pid = self()

      stub = fn pattern ->
        send(test_pid, {:unsubscribed, pattern})
        :ok
      end

      DynamicTool.execute(
        "aiur_unsubscribe",
        %{"topic_pattern" => "ticket.42.#"},
        unsubscriber: stub
      )

      assert_receive {:unsubscribed, "ticket.42.#"}, 200
    end

    test "rejects empty / malformed patterns" do
      stub = fn _ -> :ok end

      for bad <- ["", ".bad", "bad.", "ticket..101"] do
        r = DynamicTool.execute("aiur_subscribe", %{"topic_pattern" => bad}, subscriber: stub)
        assert r["success"] == false
      end
    end

    test "missing pattern returns error" do
      stub = fn _ -> :ok end
      r = DynamicTool.execute("aiur_subscribe", %{}, subscriber: stub)
      assert r["success"] == false
    end

    test "missing injected closure returns unavailable error" do
      r = DynamicTool.execute("aiur_subscribe", %{"topic_pattern" => "x"})
      assert r["success"] == false
      assert Jason.decode!(r["output"])["error"]["message"] =~ "unavailable"
    end
  end

  describe "aiur_declare_blocker / aiur_unblock — Wave 0 characterization" do
    test "declare_blocker success payload shape with atom result rendered as string" do
      response =
        DynamicTool.execute(
          "aiur_declare_blocker",
          %{"issue_number" => 42},
          blocker_declarer: fn _n -> {:ok, :already_declared} end
        )

      assert response["success"] == true
      decoded = Jason.decode!(response["output"])
      assert decoded["ok"] == true
      assert decoded["issue_number"] == 42
      assert decoded["result"] == "already_declared"
    end

    test "unblock success payload shape" do
      response =
        DynamicTool.execute(
          "aiur_unblock",
          %{"issue_number" => 10},
          unblocker: fn _n -> {:ok, :removed} end
        )

      assert response["success"] == true
      decoded = Jason.decode!(response["output"])
      assert decoded["ok"] == true
      assert decoded["issue_number"] == 10
      assert decoded["result"] == "removed"
    end

    test "normalize_issue_number: string input is parsed and trimmed" do
      response =
        DynamicTool.execute(
          "aiur_declare_blocker",
          %{"issue_number" => "  99  "},
          blocker_declarer: fn n -> {:ok, n} end
        )

      assert response["success"] == true
      assert Jason.decode!(response["output"])["issue_number"] == 99
    end

    test "normalize_issue_number: zero is rejected" do
      response =
        DynamicTool.execute(
          "aiur_declare_blocker",
          %{"issue_number" => 0},
          blocker_declarer: fn _n -> {:ok, :ok} end
        )

      assert response["success"] == false
    end

    test "normalize_issue_number: negative integer is rejected" do
      response =
        DynamicTool.execute(
          "aiur_declare_blocker",
          %{"issue_number" => -5},
          blocker_declarer: fn _n -> {:ok, :ok} end
        )

      assert response["success"] == false
    end

    test "normalize_issue_number: missing key returns missing_issue_number" do
      response =
        DynamicTool.execute(
          "aiur_declare_blocker",
          %{},
          blocker_declarer: fn _n -> {:ok, :ok} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "required"
    end

    test "blocker_declarer_unavailable when closure is absent" do
      response = DynamicTool.execute("aiur_declare_blocker", %{"issue_number" => 1})
      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "unavailable"
    end

    test "unblocker_unavailable when closure is absent" do
      response = DynamicTool.execute("aiur_unblock", %{"issue_number" => 1})
      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "unavailable"
    end

    test "cycle_detected error rendering" do
      response =
        DynamicTool.execute(
          "aiur_declare_blocker",
          %{"issue_number" => 5},
          blocker_declarer: fn _n -> {:error, :cycle_detected} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "cycle"
    end

    test "blocker_not_found error rendering" do
      response =
        DynamicTool.execute(
          "aiur_declare_blocker",
          %{"issue_number" => 9999},
          blocker_declarer: fn _n -> {:error, :blocker_not_found} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "does not exist"
    end

    test "rate_limited error rendering" do
      response =
        DynamicTool.execute(
          "aiur_declare_blocker",
          %{"issue_number" => 5},
          blocker_declarer: fn _n -> {:error, :rate_limited} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "API budget"
    end

    test "permission_denied error rendering" do
      response =
        DynamicTool.execute(
          "aiur_declare_blocker",
          %{"issue_number" => 5},
          blocker_declarer: fn _n -> {:error, :permission_denied} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "lacks Issues:write"
    end
  end

  describe "catch-all error payload" do
    test "non-linear tool returning an unexpected error renders the shared catch-all message" do
      response =
        DynamicTool.execute(
          "emit_event",
          %{"name" => "blocked", "message" => "test"},
          event_publisher: fn _name, _message, _payload -> {:error, :unexpected} end
        )

      assert response["success"] == false
      decoded = Jason.decode!(response["output"])
      assert decoded["error"]["message"] == "Aiur tool execution failed."
      assert decoded["error"]["reason"] == ":unexpected"
    end
  end

  describe "emit_alert severity paths — Wave 0 characterization" do
    test "explicit severity passthrough" do
      test_pid = self()

      DynamicTool.execute(
        "emit_alert",
        %{
          "name" => "phase.work.start",
          "message" => "Working",
          "reason" => "started",
          "needs_attention" => false,
          "severity" => "critical"
        },
        alert_emitter: fn name, message, reason, needs_attention, severity ->
          send(test_pid, {:emitted, name, message, reason, needs_attention, severity})
          :ok
        end
      )

      assert_received {:emitted, "phase.work.start", "Working", "started", false, "critical"}
    end

    test "needs_attention: true defaults severity to warning" do
      test_pid = self()

      response =
        DynamicTool.execute(
          "emit_alert",
          %{
            "name" => "phase.work.start",
            "message" => "Urgent",
            "reason" => "urgent reason",
            "needs_attention" => true
          },
          alert_emitter: fn name, message, reason, needs_attention, severity ->
            send(test_pid, {:emitted, name, message, reason, needs_attention, severity})
            :ok
          end
        )

      assert response["success"] == true
      assert_received {:emitted, "phase.work.start", "Urgent", "urgent reason", true, "warning"}
    end
  end

  describe "atom-key argument variants — Wave 0 characterization" do
    test "aiur_subscribe accepts atom-key topic_pattern" do
      test_pid = self()

      response =
        DynamicTool.execute(
          "aiur_subscribe",
          %{topic_pattern: "ticket.42.#"},
          subscriber: fn pattern ->
            send(test_pid, {:subscribed, pattern})
            :ok
          end
        )

      assert response["success"] == true
      assert_received {:subscribed, "ticket.42.#"}
    end

    test "emit_alert accepts atom-key name and message" do
      test_pid = self()

      response =
        DynamicTool.execute(
          "emit_alert",
          %{name: "phase.plan.start", message: "Planning"},
          alert_emitter: fn name, message, _reason, _needs_attention, _severity ->
            send(test_pid, {:emitted, name, message})
            :ok
          end
        )

      assert response["success"] == true
      assert_received {:emitted, "phase.plan.start", "Planning"}
    end

    test "aiur_declare_blocker accepts atom-key issue_number" do
      response =
        DynamicTool.execute(
          "aiur_declare_blocker",
          %{issue_number: 7},
          blocker_declarer: fn n -> {:ok, n} end
        )

      assert response["success"] == true
      assert Jason.decode!(response["output"])["issue_number"] == 7
    end
  end

  describe "emit_event publisher arity gate — Wave 0 characterization" do
    test "wrong-arity publisher (fn/2) returns event_publisher_unavailable" do
      response =
        DynamicTool.execute(
          "emit_event",
          %{"name" => "blocked", "message" => "test"},
          event_publisher: fn _name, _message -> {:ok, %{}} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "unavailable"
    end
  end
end
