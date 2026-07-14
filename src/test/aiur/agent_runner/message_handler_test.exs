defmodule Aiur.AgentRunner.MessageHandlerTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentPubSub, Issue}
  alias Aiur.AgentRunner.MessageHandler
  alias Aiur.AgentEvents
  alias Aiur.GitHub.AgentCommentOrigins

  setup do
    path = Path.join(System.tmp_dir!(), "aiur-message-handler-origins-#{System.unique_integer([:positive])}.json")
    previous_path = Application.get_env(:aiur, :agent_comment_origins_path)
    Application.put_env(:aiur, :agent_comment_origins_path, path)

    on_exit(fn ->
      File.rm(path)

      if previous_path do
        Application.put_env(:aiur, :agent_comment_origins_path, previous_path)
      else
        Application.delete_env(:aiur, :agent_comment_origins_path)
      end
    end)

    :ok
  end

  describe "build/6" do
    test "treats nil lifecycle options as an empty option list" do
      issue = %Issue{id: "gid-mh-nil", identifier: "MH-nil"}
      handler = MessageHandler.build(nil, issue, nil, nil, "codex", nil, nil)

      assert :ok = handler.(%{event: :agent_message, body: "test"})
    end

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

    test "records successful gh pr comments against the active ticket" do
      issue = %Issue{id: "gid-mh-09", identifier: "MH-09"}

      handler =
        MessageHandler.build(nil, issue, nil, nil, "codex", nil,
          agent_comment_origin_recorder: fn ticket, command, output, exit_code ->
            send(self(), {:comment_origin, ticket, command, output, exit_code})
            :ok
          end
        )

      handler.(%{
        event: :notification,
        payload: %{
          method: "item/completed",
          params: %{
            item: %{
              type: "commandExecution",
              command: "gh pr comment 1153 --body 'Resolved.'",
              aggregatedOutput: "https://github.com/its-everdred/aiur/pull/1153#issuecomment-7006\n",
              exitCode: 0
            }
          }
        }
      })

      assert_receive {:comment_origin, "MH-09", "gh pr comment 1153 --body 'Resolved.'", _output, 0}
    end

    test "holds top-level comment classification until the exact origin is persisted" do
      issue = %Issue{id: "gid-mh-atomic", identifier: "MH-atomic"}
      comment_id = System.unique_integer([:positive])
      approval_id = "public-comment-approval-#{comment_id}"
      operation_id = "public-comment-execution-#{comment_id}"
      handler = MessageHandler.build(nil, issue, nil, nil, "codex")

      assert :ok =
               handler.(%{
                 event: :command_execution_preapproved,
                 payload: %{
                   id: approval_id,
                   method: "item/commandExecution/requestApproval",
                   params: %{command: "gh pr comment 1153 --body 'Resolved.'"}
                 }
               })

      assert :ok =
               handler.(%{
                 event: :notification,
                 payload: %{
                   method: "item/started",
                   params: %{
                     item: %{
                       id: operation_id,
                       type: "commandExecution",
                       command: "gh pr comment 1153 --body 'Resolved.'"
                     }
                   }
                 }
               })

      assert {:error, {:pending_origin_recovery, _operation_ids}} =
               AgentCommentOrigins.origin(issue.identifier, %{"id" => comment_id})

      assert :ok =
               handler.(%{
                 event: :notification,
                 payload: %{
                   method: "item/completed",
                   params: %{
                     item: %{
                       id: operation_id,
                       type: "commandExecution",
                       command: "gh pr comment 1153 --body 'Resolved.'",
                       aggregatedOutput: "https://github.com/owner/repo/pull/1153#issuecomment-#{comment_id}\n",
                       exitCode: 0
                     }
                   }
                 }
               })

      assert AgentCommentOrigins.origin(issue.identifier, %{"id" => comment_id}) == {:ok, :agent}
    end

    test "records a legacy Codex command approval before its public comment starts" do
      issue = %Issue{id: "gid-mh-legacy", identifier: "MH-legacy"}
      operation_id = "legacy-public-comment-#{System.unique_integer([:positive])}"
      handler = MessageHandler.build(nil, issue, nil, nil, "codex")

      assert :ok =
               handler.(%{
                 event: :command_execution_preapproved,
                 payload: %{
                   id: operation_id,
                   method: "execCommandApproval",
                   params: %{command: "gh pr comment 1153 --body 'Resolved.'"}
                 }
               })

      assert {:error, {:pending_origin_recovery, [^operation_id]}} =
               AgentCommentOrigins.origin(issue.identifier, %{"id" => 70_016})
    end

    test "completes a Claude transcript result from a durable pre-tool operation" do
      issue = %Issue{id: "gid-mh-claude", identifier: "MH-claude"}
      operation_id = "toolu-#{System.unique_integer([:positive])}"
      comment_id = System.unique_integer([:positive])

      assert :ok =
               AgentCommentOrigins.begin_gh_pr_comment(
                 issue.identifier,
                 "gh pr comment 1153 --body 'Resolved.'",
                 operation_id
               )

      handler = MessageHandler.build(nil, issue, nil, nil, "claude-repl")

      assert :ok =
               handler.(%{
                 event: :transcript,
                 transcript_event:
                   AgentEvents.transcript_event(:tool, "tool result",
                     payload: %{
                       tool: "result",
                       output: "https://github.com/owner/repo/pull/1153#issuecomment-#{comment_id}\n",
                       exit_code: 0,
                       operation_id: operation_id
                     }
                   )
               })

      assert AgentCommentOrigins.origin(issue.identifier, %{"id" => comment_id}) == {:ok, :agent}
    end

    test "keeps a durable agent-origin quarantine after recording failure" do
      issue = %Issue{id: "gid-mh-origin-quarantine", identifier: "MH-origin-quarantine"}
      comment_id = System.unique_integer([:positive])
      approval_id = "public-comment-approval-#{comment_id}"
      operation_id = "public-comment-execution-#{comment_id}"

      task =
        Task.async(fn ->
          handler =
            MessageHandler.build(nil, issue, nil, nil, "codex", nil,
              agent_comment_origin_recorder: fn _ticket, _command, _output, _exit_code ->
                {:error, :disk_full}
              end
            )

          assert :ok =
                   handler.(%{
                     event: :command_execution_preapproved,
                     payload: %{
                       id: approval_id,
                       method: "item/commandExecution/requestApproval",
                       params: %{command: "gh pr comment 1153 --body 'Resolved.'"}
                     }
                   })

          assert :ok =
                   handler.(%{
                     event: :notification,
                     payload: %{
                       method: "item/started",
                       params: %{
                         item: %{
                           id: operation_id,
                           type: "commandExecution",
                           command: "gh pr comment 1153 --body 'Resolved.'"
                         }
                       }
                     }
                   })

          handler.(%{
            event: :notification,
            payload: %{
              method: "item/completed",
              params: %{
                item: %{
                  id: operation_id,
                  type: "commandExecution",
                  command: "gh pr comment 1153 --body 'Resolved.'",
                  aggregatedOutput: "https://github.com/owner/repo/pull/1153#issuecomment-#{comment_id}\n",
                  exitCode: 0
                }
              }
            }
          })
        end)

      assert {:error, {:agent_comment_origin_not_recorded, :disk_full}} = Task.await(task, 2_000)

      assert AgentCommentOrigins.origin(issue.identifier, %{"id" => comment_id}) == {:ok, :agent}

      assert {:error, {:pending_origin_recovery, _operation_ids}} =
               AgentCommentOrigins.origin(issue.identifier, %{"id" => comment_id + 1})
    end

    test "registers Codex session-approved comments that have no approval event" do
      issue = %Issue{id: "gid-mh-no-approval", identifier: "MH-no-approval"}
      comment_id = System.unique_integer([:positive])
      operation_id = "public-comment-no-approval-#{comment_id}"
      handler = MessageHandler.build(nil, issue, nil, nil, "codex")

      assert :ok =
               handler.(%{
                 event: :notification,
                 payload: %{
                   method: "item/started",
                   params: %{
                     item: %{
                       id: operation_id,
                       type: "commandExecution",
                       command: "gh pr comment 1153 --body 'Resolved without a prompt.'"
                     }
                   }
                 }
               })

      assert {:error, {:pending_origin_recovery, [^operation_id]}} =
               AgentCommentOrigins.origin(issue.identifier, %{"id" => comment_id})

      assert :ok =
               handler.(%{
                 event: :notification,
                 payload: %{
                   method: "item/completed",
                   params: %{
                     item: %{
                       id: operation_id,
                       type: "commandExecution",
                       command: "gh pr comment 1153 --body 'Resolved without a prompt.'",
                       aggregatedOutput: "https://github.com/owner/repo/pull/1153#issuecomment-#{comment_id}\n",
                       exitCode: 0
                     }
                   }
                 }
               })

      assert AgentCommentOrigins.origin(issue.identifier, %{"id" => comment_id}) == {:ok, :agent}
    end

    test "records a visible top-level comment even when a later shell segment fails" do
      issue = %Issue{id: "gid-mh-partial", identifier: "MH-partial"}
      comment_id = System.unique_integer([:positive])
      operation_id = "public-comment-partial-#{comment_id}"
      handler = MessageHandler.build(nil, issue, nil, nil, "codex")

      assert :ok =
               handler.(%{
                 event: :notification,
                 payload: %{
                   method: "item/started",
                   params: %{
                     item: %{
                       id: operation_id,
                       type: "commandExecution",
                       command: "gh pr comment 1153 --body 'Resolved.'"
                     }
                   }
                 }
               })

      assert :ok =
               handler.(%{
                 event: :notification,
                 payload: %{
                   method: "item/completed",
                   params: %{
                     item: %{
                       id: operation_id,
                       type: "commandExecution",
                       command: "gh pr comment 1153 --body 'Resolved.'",
                       aggregatedOutput: "https://github.com/owner/repo/pull/1153#issuecomment-#{comment_id}\n",
                       exitCode: 1
                     }
                   }
                 }
               })

      assert AgentCommentOrigins.origin(issue.identifier, %{"id" => comment_id}) == {:ok, :agent}
    end

    test "correlates Claude's split Bash command and result notifications" do
      issue = %Issue{id: "gid-mh-claude", identifier: "MH-claude"}
      test_pid = self()

      handler =
        MessageHandler.build(nil, issue, nil, nil, "claude", nil,
          agent_comment_origin_recorder: fn ticket, command, output, exit_code ->
            send(test_pid, {:comment_origin, ticket, command, output, exit_code})
            :ok
          end
        )

      assert :ok =
               handler.(%{
                 event: :notification,
                 payload: %{
                   method: "item/created",
                   params: %{
                     item: %{
                       id: "claude-comment-command",
                       tool_use_id: "claude-comment-command",
                       type: "tool_call",
                       name: "Bash",
                       input: %{command: "gh pr comment 1153 --body 'Resolved.'"}
                     }
                   }
                 }
               })

      assert :ok =
               handler.(%{
                 event: :notification,
                 payload: %{
                   method: "item/created",
                   params: %{
                     item: %{
                       id: "claude-comment-result",
                       tool_use_id: "claude-comment-command",
                       type: "tool_result",
                       content: "https://github.com/owner/repo/pull/1153#issuecomment-7010\n",
                       is_error: false
                     }
                   }
                 }
               })

      assert_receive {:comment_origin, "MH-claude", "gh pr comment 1153 --body 'Resolved.'", _output, 0}
    end

    test "returns an actionable error when a visible public comment cannot be recorded" do
      issue = %Issue{id: "gid-mh-origin-error", identifier: "MH-origin-error"}

      handler =
        MessageHandler.build(nil, issue, nil, nil, "codex", nil,
          agent_comment_origin_recorder: fn _ticket, _command, _output, _exit_code ->
            {:error, :disk_full}
          end
        )

      assert {:error, {:agent_comment_origin_not_recorded, :disk_full}} =
               handler.(%{
                 event: :notification,
                 payload: %{
                   method: "item/completed",
                   params: %{
                     item: %{
                       type: "commandExecution",
                       command: "gh pr comment 1153 --body 'Resolved.'",
                       aggregatedOutput: "https://github.com/owner/repo/pull/1153#issuecomment-7011\n",
                       exitCode: 0
                     }
                   }
                 }
               })
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
end
