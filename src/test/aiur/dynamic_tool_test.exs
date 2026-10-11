defmodule Aiur.Codex.DynamicToolTest do
  use Aiur.TestSupport
  alias Aiur.Codex.DynamicTool

  test "tool_specs advertises the linear_graphql, review thread, and emit_alert contracts" do
    specs = DynamicTool.tool_specs()

    assert Enum.any?(specs, fn
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{"query" => _, "variables" => _},
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             } ->
               description =~ "Linear"

             _ ->
               false
           end)

    assert Enum.any?(specs, fn
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{"review_thread_id" => _, "body" => _},
                 "required" => ["review_thread_id", "body"],
                 "type" => "object"
               },
               "name" => "aiur_reply_review_thread"
             } ->
               description =~ "review thread"

             _ ->
               false
           end)

    assert Enum.any?(specs, fn
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{"review_thread_id" => _, "terminal_reply_body" => _},
                 "required" => ["review_thread_id", "terminal_reply_body"],
                 "type" => "object"
               },
               "name" => "aiur_resolve_review_thread"
             } ->
               description =~ "Resolve"

             _ ->
               false
           end)

    assert Enum.any?(specs, fn
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "reason" => %{"description" => reason_description},
                   "needs_attention" => %{"description" => attention_description},
                   "severity" => _
                 },
                 "required" => ["name", "message", "reason", "needs_attention"]
               },
               "name" => "emit_alert"
             } ->
               description =~ "Executor context" and
                 reason_description =~ "Executor should relay" and
                 attention_description =~ "Executor should look or act"

             _ ->
               false
           end)
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => [
                 "linear_graphql",
                 "aiur_reply_review_thread",
                 "aiur_resolve_review_thread",
                 "emit_alert",
                 "emit_event",
                 "aiur_subscribe",
                 "aiur_unsubscribe",
                 "aiur_declare_blocker",
                 "aiur_unblock",
                 "aiur_set_ticket_state",
                 "aiur_set_epic"
               ]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "aiur_reply_review_thread returns verified reply payloads" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "aiur_reply_review_thread",
        %{
          "review_thread_id" => "PRRT_verified",
          "body" => "Verified on this branch."
        },
        review_thread_replier: fn review_thread_id, body, opts ->
          send(test_pid, {:reply_review_thread_called, review_thread_id, body, opts})
          {:ok, %{verified: true, review_thread_id: review_thread_id}}
        end
      )

    assert_received {:reply_review_thread_called, "PRRT_verified", "Verified on this branch.", []}
    assert response["success"] == true

    assert Jason.decode!(response["output"]) == %{
             "review_thread_id" => "PRRT_verified",
             "verified" => true
           }
  end

  test "aiur_reply_review_thread surfaces unverified replies as failures" do
    response =
      DynamicTool.execute(
        "aiur_reply_review_thread",
        %{
          "review_thread_id" => "PRRT_unverified",
          "body" => "Verified on this branch."
        },
        review_thread_replier: fn _review_thread_id, _body, _opts ->
          {:error, {:review_thread_reply_not_verified, %{attempts: 3}}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"])["error"]["reason"] ==
             "review_thread_reply_not_verified"
  end

  test "aiur_resolve_review_thread returns resolved payloads" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "aiur_resolve_review_thread",
        %{
          "review_thread_id" => "PRRT_done",
          "terminal_reply_body" => "Done, no further changes."
        },
        review_thread_resolver: fn review_thread_id, opts ->
          send(test_pid, {:resolve_review_thread_called, review_thread_id, opts})
          {:ok, %{resolved: true, review_thread_id: review_thread_id}}
        end
      )

    assert_received {:resolve_review_thread_called, "PRRT_done", [terminal_reply_body: "Done, no further changes."]}

    assert response["success"] == true

    assert Jason.decode!(response["output"]) == %{
             "resolved" => true,
             "review_thread_id" => "PRRT_done"
           }
  end

  test "aiur_resolve_review_thread surfaces token permission failures explicitly" do
    response =
      DynamicTool.execute(
        "aiur_resolve_review_thread",
        %{
          "review_thread_id" => "PRRT_denied",
          "terminal_reply_body" => "Done, no further changes."
        },
        review_thread_resolver: fn _review_thread_id, _opts ->
          {:error,
           {:review_thread_resolution_not_permitted,
            %{
              review_thread_id: "PRRT_denied",
              required_permission: "Pull requests: Read and write"
            }}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"])["error"] == %{
             "message" => "GitHub review thread resolution was not permitted by the configured token.",
             "reason" => "review_thread_resolution_not_permitted",
             "detail" => %{
               "required_permission" => "Pull requests: Read and write",
               "review_thread_id" => "PRRT_denied"
             }
           }
  end

  test "emit_alert invokes the provided emitter for custom scopes" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "emit_alert",
        %{
          "name" => "phase.work.start",
          "message" => "Entered implementation",
          "reason" => "work phase started",
          "needs_attention" => false
        },
        alert_emitter: fn name, message, reason, needs_attention, severity ->
          send(test_pid, {:alert_emitted, name, message, reason, needs_attention, severity})
          :ok
        end
      )

    assert_received {:alert_emitted, "phase.work.start", "Entered implementation", "work phase started", false, "info"}

    assert response["success"] == true
  end

  test "emit_alert accepts legacy payloads and defaults structured fields" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "emit_alert",
        %{
          "name" => "phase.plan.start",
          "message" => "Planning"
        },
        alert_emitter: fn name, message, reason, needs_attention, severity ->
          send(test_pid, {:alert_emitted, name, message, reason, needs_attention, severity})
          :ok
        end
      )

    assert_received {:alert_emitted, "phase.plan.start", "Planning", "Planning", false, "info"}
    assert response["success"] == true
  end

  test "emit_alert supports legacy two-argument emitters" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "emit_alert",
        %{
          "name" => "phase.review.start",
          "message" => "Reviewing",
          "reason" => "self-review started",
          "needs_attention" => false
        },
        alert_emitter: fn name, message ->
          send(test_pid, {:legacy_alert_emitted, name, message})
          :ok
        end
      )

    assert_received {:legacy_alert_emitted, "phase.review.start", "Reviewing"}
    assert response["success"] == true
  end

  test "emit_alert rejects explicit non-boolean needs_attention" do
    response =
      DynamicTool.execute(
        "emit_alert",
        %{
          "name" => "phase.review.start",
          "message" => "Reviewing",
          "needs_attention" => "false"
        },
        alert_emitter: fn _name, _message, _reason, _needs_attention, _severity -> :ok end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"])["error"]["message"] ==
             "`emit_alert.needs_attention` must be true or false."
  end

  test "emit_alert rejects reserved system scopes" do
    response =
      DynamicTool.execute(
        "emit_alert",
        %{
          "name" => "task.done",
          "message" => "Completed",
          "reason" => "attempted system scope",
          "needs_attention" => true,
          "severity" => "critical"
        },
        alert_emitter: fn _name, _message, _reason, _needs_attention, _severity ->
          {:error, :system_scope_reserved}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`emit_alert` may not emit system-owned alerts under `task.*`, `agent.*`, or `chat.*`."
             }
           }
  end
end
