defmodule Aiur.AgentRunner.MessageHandlerTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentPubSub, Issue, LiveConversation, TrackerIdentity}
  alias Aiur.AgentRunner.MessageHandler

  describe "build/6" do
    test "returns a closure that forwards codex_worker_update to recipient" do
      issue = %Issue{id: "gid-mh-01", identifier: "MH-01"}
      handler = MessageHandler.build(self(), issue, nil, nil, "codex")
      message = %{event: :agent_message, body: "hello"}

      handler.(message)

      assert_receive {:codex_worker_update, "gid-mh-01", _normalized}, 2_000
    end

    test "no-ops codex_worker_update for nil recipient" do
      issue = %Issue{id: "gid-mh-02", identifier: "MH-02"}
      handler = MessageHandler.build(nil, issue, nil, nil, "codex")

      assert :ok = handler.(%{event: :agent_message, body: "test"})
      refute_receive {:codex_worker_update, _, _}, 100
    end

    test "broadcasts a transcript event for an issue with binary identifier" do
      identifier = "MH-t-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-mh-03", identifier: identifier}
      :ok = AgentPubSub.subscribe_agent(identifier)

      handler = MessageHandler.build(nil, issue, nil, nil, "codex")
      handler.(%{event: :agent_message, body: "transcript content"})

      assert_receive {:transcript_event, _event}, 2_000
    end

    test "skips transcript broadcast for an empty body" do
      identifier = "MH-empty-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-mh-04", identifier: identifier}
      :ok = AgentPubSub.subscribe_agent(identifier)

      handler = MessageHandler.build(nil, issue, nil, nil, "codex")
      handler.(%{event: :agent_message, body: ""})

      refute_receive {:transcript_event, _event}, 500
    end

    test "broadcasts a turn event when turn_id is binary and event kind is terminal" do
      identifier = "MH-turn-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-mh-05", identifier: identifier}
      :ok = AgentPubSub.subscribe_agent(identifier)

      turn_id = "t#{System.unique_integer([:positive])}"
      handler = MessageHandler.build(nil, issue, nil, nil, "codex", turn_id)
      handler.(%{event: :turn_completed})

      assert_receive {:turn_event, ^identifier, :turn_completed, _payload}, 2_000
    end

    test "does not send a turn event when turn_id is nil" do
      identifier = "MH-noturn-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-mh-06", identifier: identifier}
      :ok = AgentPubSub.subscribe_agent(identifier)

      handler = MessageHandler.build(nil, issue, nil, nil, "codex")
      handler.(%{event: :turn_completed})

      refute_receive {:turn_event, _, _, _}, 200
    end

    test "tolerates string-keyed messages (event_kind uses MapAccess)" do
      issue = %Issue{id: "gid-mh-07", identifier: "MH-07"}
      handler = MessageHandler.build(self(), issue, nil, nil, "codex")
      message = %{"event" => "agent_message", "body" => "string-keyed"}

      handler.(message)

      assert_receive {:codex_worker_update, "gid-mh-07", _normalized}, 2_000
    end

    test "observes raw backend operation boundaries before transcript extraction" do
      issue = %Issue{id: "gid-mh-08", identifier: "930"}

      recorder = fn kind, attributes, opts ->
        send(self(), {:lifecycle, kind, attributes, opts})
        :ok
      end

      handler =
        MessageHandler.build(nil, issue, nil, nil, "codex", nil,
          attempt_id: "attempt-1",
          recorder: recorder
        )

      handler.(%{
        event: :notification,
        payload: %{
          method: "item/started",
          params: %{item: %{id: "cmd-1", type: "commandExecution", command: "mix test"}}
        }
      })

      assert_receive {:lifecycle, :lifecycle, %{event: "build_test", boundary: "start", operation_id: "cmd-1"}, _opts}
    end

    test "projects only fixed prose from completed tool results" do
      unique = Integer.to_string(System.unique_integer([:positive]))
      identity = tracker_identity(unique)

      issue = %Issue{id: "gid-tool-#{unique}", identifier: unique, tracker_identity: identity}
      source = %{identity: identity, attempt_id: "attempt-#{unique}", backend: "codex", worker_generation: 1}

      handler =
        MessageHandler.build(nil, issue, nil, nil, "codex", nil,
          attempt_id: "attempt-#{unique}",
          worker_generation: 1
        )

      handler.(%{
        event: :notification,
        payload: %{
          method: "item/completed",
          params: %{
            item: %{
              id: "tool-1",
              type: "dynamicToolCall",
              tool: "dangerous_tool",
              arguments: ~s({"token":"ghp_abcdefghijklmnopqrstuvwxyz0123456789"}),
              contentItems: [%{text: "/private/full/output"}],
              success: true
            }
          }
        }
      })

      assert %{messages: [%{role: "tool", title: "Tool result", body: "Tool completed"}]} =
               LiveConversation.snapshot(source)

      refute inspect(LiveConversation.snapshot(source)) =~ "dangerous_tool"
      refute inspect(LiveConversation.snapshot(source)) =~ "private/full/output"
    end

    test "projects operator deliveries using the runner telemetry attempt id" do
      unique = Integer.to_string(System.unique_integer([:positive]))
      identity = tracker_identity(unique)
      issue = %Issue{id: "gid-operator-#{unique}", identifier: unique, tracker_identity: identity}

      item = %{
        id: System.unique_integer([:positive]),
        category: :operator_message,
        body: %{text: "Please continue"}
      }

      assert :ok =
               MessageHandler.observe_operator_delivery(issue, item, "codex",
                 telemetry_attempt_id: "attempt-#{unique}",
                 worker_generation: 2
               )

      source = %{identity: identity, attempt_id: "attempt-#{unique}", backend: "codex", worker_generation: 2}

      assert %{messages: [%{role: "operator", body: "Please continue"}]} =
               LiveConversation.snapshot(source)
    end
  end

  describe "send_control_state/3" do
    test "sends :paused worker_control_state to a pid recipient" do
      issue = %Issue{id: "gid-sc-01"}

      MessageHandler.send_control_state(self(), issue, :paused)

      assert_receive {:worker_control_state, "gid-sc-01", :paused}, 2_000
    end

    test "sends :working worker_control_state to a pid recipient" do
      issue = %Issue{id: "gid-sc-02"}

      MessageHandler.send_control_state(self(), issue, :working)

      assert_receive {:worker_control_state, "gid-sc-02", :working}, 2_000
    end

    test "sends :completed worker_control_state to a pid recipient" do
      issue = %Issue{id: "gid-sc-completed"}

      MessageHandler.send_control_state(self(), issue, :completed)

      assert_receive {:worker_control_state, "gid-sc-completed", :completed}, 2_000
    end

    test "preserves a worker pause payload" do
      issue = %Issue{id: "gid-sc-03"}
      pause_payload = %{kind: :usage_limit_exhausted, reset_hint: "23:00 UTC"}

      MessageHandler.send_control_state(self(), issue, :paused, pause_payload)

      assert_receive {:worker_control_state, "gid-sc-03", :paused, ^pause_payload}, 2_000
    end

    test "no-ops for a nil recipient" do
      issue = %Issue{id: "gid-sc-03"}
      assert :ok = MessageHandler.send_control_state(nil, issue, :paused)
    end

    test "no-ops for a non-binary issue id" do
      issue = %Issue{id: nil, identifier: "SC-04"}
      assert :ok = MessageHandler.send_control_state(self(), issue, :paused)
      refute_receive {:worker_control_state, _, _}, 100
    end

    test "no-ops for an unrecognized status" do
      issue = %Issue{id: "gid-sc-05"}
      assert :ok = MessageHandler.send_control_state(self(), issue, :unknown_status)
      refute_receive {:worker_control_state, _, _}, 100
    end
  end

  describe "send_worker_runtime_info/4" do
    test "sends worker_runtime_info to a pid recipient with binary workspace" do
      issue = %Issue{id: "gid-wri-01"}

      MessageHandler.send_worker_runtime_info(self(), issue, "host-1", "/workspace/path")

      assert_receive {:worker_runtime_info, "gid-wri-01", %{worker_host: "host-1", workspace_path: "/workspace/path"}},
                     2_000
    end

    test "no-ops when workspace is nil" do
      issue = %Issue{id: "gid-wri-02"}
      assert :ok = MessageHandler.send_worker_runtime_info(self(), issue, "host", nil)
      refute_receive {:worker_runtime_info, _, _}, 100
    end

    test "no-ops for a nil recipient" do
      issue = %Issue{id: "gid-wri-03"}
      assert :ok = MessageHandler.send_worker_runtime_info(nil, issue, "host", "/path")
    end

    test "no-ops for a non-binary issue id" do
      issue = %Issue{id: nil, identifier: "WRI-04"}
      assert :ok = MessageHandler.send_worker_runtime_info(self(), issue, "host", "/path")
      refute_receive {:worker_runtime_info, _, _}, 100
    end
  end

  defp tracker_identity(identifier) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "provider-#{identifier}",
      identifier: identifier,
      reason: nil
    }
  end
end
