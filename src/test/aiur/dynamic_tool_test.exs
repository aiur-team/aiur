defmodule Aiur.Codex.DynamicToolTest do
  use Aiur.TestSupport

  alias Aiur.Codex.DynamicTool

  test "tool_specs advertises the linear_graphql, review reply, and emit_alert contracts" do
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
               "inputSchema" => %{
                 "properties" => %{"reason" => _, "needs_attention" => _, "severity" => _},
                 "required" => ["name", "message", "reason", "needs_attention"]
               },
               "name" => "emit_alert"
             } ->
               true

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
                 "emit_alert",
                 "emit_event",
                 "aiur_subscribe",
                 "aiur_unsubscribe",
                 "aiur_declare_blocker",
                 "aiur_unblock"
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

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})

          {:ok,
           %{
             "errors" => [
               %{
                 "message" => "Must provide operation name if query contains multiple operations."
               }
             ]
           }}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Aiur is missing Linear auth. Set `linear.api_key` in `.aiurconfig` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:error, {:linear_api_request, :timeout}}
        end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end

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
      assert Enum.any?(DynamicTool.tool_specs(), &(&1["name"] == "emit_event"))
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
end
