defmodule Aiur.AgentRunner.MessageHandlerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

    test "deduplicates replayed tool results using provider identity" do
      unique = Integer.to_string(System.unique_integer([:positive]))
      identity = tracker_identity(unique)
      issue = %Issue{id: "gid-tool-replay-#{unique}", identifier: unique, tracker_identity: identity}
      source = %{identity: identity, attempt_id: "attempt-#{unique}", backend: "codex", worker_generation: 1}

      handler =
        MessageHandler.build(nil, issue, nil, nil, "codex", nil,
          attempt_id: "attempt-#{unique}",
          worker_generation: 1
        )

      completed_tool = %{
        event: :notification,
        payload: %{
          method: "item/completed",
          params: %{
            item: %{
              id: "provider-tool-#{unique}",
              type: "dynamicToolCall",
              tool: "safe_tool",
              success: true
            }
          }
        }
      }

      handler.(completed_tool)
      handler.(completed_tool)

      assert %{messages: [%{id: id, role: "tool", body: "Tool completed"}]} =
               LiveConversation.snapshot(source)

      refute id =~ "provider-tool"

      handler.(put_in(completed_tool, [:payload, :params, :item], %{type: "dynamicToolCall", success: true}))
      assert %{messages: [_single_safe_summary]} = LiveConversation.snapshot(source)
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

    test "never projects coordination events as operator messages" do
      unique = Integer.to_string(System.unique_integer([:positive]))
      identity = tracker_identity(unique)
      issue = %Issue{id: "gid-coordination-#{unique}", identifier: unique, tracker_identity: identity}

      item = %{
        id: System.unique_integer([:positive]),
        category: :coordination_event,
        event_type: :ticket,
        body: %{summary: "cross-ticket secret"}
      }

      assert :ok =
               MessageHandler.observe_operator_delivery(issue, item, "codex",
                 telemetry_attempt_id: "attempt-#{unique}",
                 worker_generation: 2
               )

      source = %{identity: identity, attempt_id: "attempt-#{unique}", backend: "codex", worker_generation: 2}
      assert %{state: :restart_unknown, messages: []} = LiveConversation.snapshot(source)
    end

    test "marks failed sources unavailable or stale and authoritative activation recovers them" do
      unique = Integer.to_string(System.unique_integer([:positive]))
      identity = tracker_identity(unique)
      issue = %Issue{id: "gid-health-#{unique}", identifier: unique, tracker_identity: identity}

      opts = [attempt_id: "attempt-#{unique}", worker_generation: 4]
      source = %{identity: identity, attempt_id: "attempt-#{unique}", backend: "codex", worker_generation: 4}
      empty_handler = MessageHandler.build(nil, issue, nil, nil, "codex", nil, opts)

      assert :ok = MessageHandler.finish_live_conversation(issue, "codex", {:error, :port_closed}, opts)
      assert %{state: :unavailable, messages: []} = LiveConversation.snapshot(source)

      empty_handler.(%{event: :agent_message, body: "known evidence"})
      assert %{state: :live, messages: [%{body: "known evidence"}]} = LiveConversation.snapshot(source)

      assert :ok = MessageHandler.finish_live_conversation(issue, "codex", {:error, :port_closed}, opts)
      assert %{state: :stale, messages: [%{body: "known evidence"}]} = LiveConversation.snapshot(source)

      _recovered_handler = MessageHandler.build(nil, issue, nil, nil, "codex", nil, opts)
      assert %{state: :live, health: :healthy, freshness: :current} = LiveConversation.snapshot(source)
    end

    test "logs projection process exits without failing the agent path" do
      unique = Integer.to_string(System.unique_integer([:positive]))
      identity = tracker_identity(unique)
      issue = %Issue{id: "gid-log-#{unique}", identifier: unique, tracker_identity: identity}
      server = start_supervised!({LiveConversation, name: nil})
      GenServer.stop(server)

      log =
        capture_log(fn ->
          assert {:error, {:live_conversation_unavailable, :observe_operator}} =
                   MessageHandler.observe_operator_delivery(
                     issue,
                     %{id: 1, category: :operator_message, body: %{text: "continue"}},
                     "codex",
                     attempt_id: "attempt-#{unique}",
                     worker_generation: 1,
                     live_conversation_server: server
                   )
        end)

      assert log =~ "Live conversation projection observe_operator failed"
      assert log =~ unique
    end

    test "returns named context errors and publishes degraded consumer status" do
      unique = Integer.to_string(System.unique_integer([:positive]))
      issue_id = "gid-context-#{unique}"

      issue = %Issue{
        id: issue_id,
        identifier: unique,
        tracker_identity: tracker_identity(unique)
      }

      item = %{id: 17, category: :operator_message, body: %{text: "accepted"}}

      log =
        capture_log(fn ->
          assert {:error, {:live_conversation_context, :missing_worker_generation}} =
                   MessageHandler.observe_operator_delivery(
                     issue,
                     item,
                     "codex",
                     attempt_id: "attempt-#{unique}",
                     live_conversation_recipient: self()
                   )
        end)

      assert log =~ "issue_id=gid-context-#{unique} issue_identifier=#{unique}"
      assert log =~ "reason_class=missing_worker_generation"

      assert_receive {:worker_runtime_info, ^issue_id,
                      %{
                        live_conversation: %{
                          generation_handle: nil,
                          state: :unavailable,
                          health: :unavailable,
                          freshness: :unknown,
                          reason: :missing_worker_generation
                        }
                      }}
    end

    test "distinguishes an intentional projection skip from invalid context" do
      unique = Integer.to_string(System.unique_integer([:positive]))
      issue_id = "gid-skip-#{unique}"
      issue = %Issue{id: issue_id, identifier: unique}
      item = %{id: 18, category: :operator_message, body: %{text: "accepted"}}

      assert :ok =
               MessageHandler.observe_operator_delivery(issue, item, "codex",
                 live_conversation: :disabled,
                 live_conversation_recipient: self()
               )

      refute_receive {:worker_runtime_info, ^issue_id, _status}, 100

      assert {:error, {:live_conversation_context, :missing_identity}} =
               MessageHandler.observe_operator_delivery(issue, item, "codex",
                 attempt_id: "attempt-#{unique}",
                 worker_generation: 1
               )
    end

    test "omits replay-unstable Codex deltas and projects their completion once" do
      unique = Integer.to_string(System.unique_integer([:positive]))
      identity = tracker_identity(unique)
      issue = %Issue{id: "gid-delta-#{unique}", identifier: unique, tracker_identity: identity}
      source = %{identity: identity, attempt_id: "attempt-#{unique}", backend: "codex", worker_generation: 3}

      handler =
        MessageHandler.build(nil, issue, nil, nil, "codex", nil,
          attempt_id: "attempt-#{unique}",
          worker_generation: 3
        )

      delta = %{
        event: :notification,
        payload: %{
          method: "item/agentMessage/delta",
          params: %{turnId: "turn-1", itemId: "message-1", delta: "partial"}
        }
      }

      handler.(delta)
      handler.(delta)

      assert %{state: :known_empty, messages: []} = LiveConversation.snapshot(source)

      handler.(%{
        event: :notification,
        payload: %{
          method: "item/completed",
          params: %{turnId: "turn-1", item: %{type: "agentMessage", id: "message-1", text: "complete"}}
        }
      })

      assert %{messages: [%{id: id, body: "complete"}]} =
               LiveConversation.snapshot(source)

      refute id == "message-1"
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
