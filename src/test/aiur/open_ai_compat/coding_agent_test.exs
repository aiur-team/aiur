defmodule Aiur.OpenAICompat.CodingAgentTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.OpenAICompat.{CodingAgent, Transport}

  # Mirrors CodingAgent's per-turn tool-round budget; pinned so the
  # round-count assertions below fail if the bound ever drifts back down.
  @max_tool_rounds 256

  setup do
    workspace =
      Path.join(
        Aiur.Config.workspace_root(),
        "aiur-openai-compat-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "sample.txt"), "workspace evidence\n")
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  test "completes a tool loop, replays reasoning content, and drains an operator message", %{workspace: workspace} do
    parent = self()

    {:ok, responses} =
      Agent.start_link(fn ->
        [
          response(%{
            "id" => "req-1",
            "model" => "kimi-k2.7-code",
            "choices" => [
              %{
                "finish_reason" => "tool_calls",
                "message" => %{
                  "role" => "assistant",
                  "content" => nil,
                  "reasoning_content" => "I should inspect the workspace.",
                  "tool_calls" => [
                    %{
                      "id" => "call-1",
                      "type" => "function",
                      "function" => %{"name" => "read_file", "arguments" => ~s({"path":"sample.txt"})}
                    }
                  ]
                }
              }
            ],
            "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 5, "total_tokens" => 25}
          }),
          response(%{
            "id" => "req-2",
            "model" => "kimi-k2.7-code",
            "choices" => [
              %{
                "finish_reason" => "stop",
                "message" => %{"role" => "assistant", "content" => "The workspace contains the expected evidence."}
              }
            ],
            "usage" => %{"prompt_tokens" => 40, "completion_tokens" => 8, "total_tokens" => 48}
          })
        ]
      end)

    request_fun = fn request ->
      send(parent, {:request, request})

      Agent.get_and_update(responses, fn
        [next | rest] -> {next, rest}
        [] -> {{:error, :unexpected_request}, []}
      end)
    end

    instance = %{
      base_url: "https://example.invalid/v1",
      api_key_env: "TEST_OPENAI_COMPAT_KEY",
      default_model: "kimi-k2.7-code",
      transport: :chat_completions,
      quirks: %{reasoning_content_replay: true}
    }

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance,
               api_key_fetcher: fn "TEST_OPENAI_COMPAT_KEY" -> "super-secret" end,
               request_fun: request_fun
             )

    on_message = fn event -> send(parent, {:event, event}) end

    checkpoint = fn
      %{kind: :tool_result} ->
        {:deliver_text, "Operator note", fn metadata -> send(parent, {:delivered, metadata}) end, fn reason -> send(parent, {:delivery_failed, reason}) end}

      _ ->
        :noop
    end

    assert {:ok, %{result: :turn_completed}} =
             CodingAgent.run_turn(session, "Inspect the workspace", issue(),
               on_message: on_message,
               on_safe_checkpoint: checkpoint
             )

    assert_receive {:request, first}
    assert first.url == "https://example.invalid/v1/chat/completions"
    assert first.headers["authorization"] == "Bearer super-secret"
    assert get_in(first.json, ["messages", Access.at(0), "content"]) == "Inspect the workspace"

    assert_receive {:request, second}
    messages = second.json["messages"]
    assistant = Enum.find(messages, &(&1["role"] == "assistant"))
    assert assistant["reasoning_content"] == "I should inspect the workspace."
    assert Enum.any?(messages, &(&1["role"] == "tool" and &1["content"] =~ "workspace evidence"))
    assert Enum.any?(messages, &(&1["role"] == "user" and &1["content"] == "Operator note"))

    assert_receive {:delivered, %{backend: "kimi", checkpoint: :tool_result}}
    refute_receive {:delivery_failed, _}

    assert_receive {:event, %{event: :reasoning, payload: %{text: "I should inspect the workspace."}}}
    assert_receive {:event, %{event: :tool_call, payload: %{name: "read_file"}}}
    assert_receive {:event, %{event: :tool_result, payload: %{output: output}}}
    assert output =~ "workspace evidence"
    assert_receive {:event, %{event: :assistant, payload: %{text: "The workspace contains the expected evidence."}}}
    assert_receive {:event, %{event: :usage, usage: %{"total_tokens" => 48}}}

    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "rejects invalid tool arguments without dispatching the tool", %{workspace: workspace} do
    parent = self()

    response =
      response(%{
        "id" => "req-invalid",
        "choices" => [
          %{
            "finish_reason" => "tool_calls",
            "message" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "id" => "bad-call",
                  "type" => "function",
                  "function" => %{"name" => "read_file", "arguments" => ~s({"path":42})}
                }
              ]
            }
          }
        ]
      })

    final = response(%{"id" => "req-final", "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Handled."}}]})
    {:ok, queue} = Agent.start_link(fn -> [response, final] end)

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "deepseek",
               instance: instance(text_tool_fallback: true),
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: queue_fun(queue, parent)
             )

    assert {:ok, _} = CodingAgent.run_turn(session, "Read it", issue(), on_message: fn event -> send(parent, {:event, event}) end)

    assert_receive {:event, %{event: :tool_result, payload: %{success: false, output: output}}}
    assert output =~ "invalid arguments"
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "executes a validated plain-text tool call when the provider omits tool_calls", %{workspace: workspace} do
    parent = self()

    fallback =
      response(%{
        "id" => "req-fallback",
        "choices" => [
          %{
            "finish_reason" => "stop",
            "message" => %{
              "role" => "assistant",
              "content" => ~s(<tool_call>{"name":"read_file","arguments":{"path":"sample.txt"}}</tool_call>)
            }
          }
        ]
      })

    final = response(%{"id" => "req-fallback-final", "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Read it."}}]})
    {:ok, queue} = Agent.start_link(fn -> [fallback, final] end)

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "deepseek",
               instance: instance(text_tool_fallback: true),
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: queue_fun(queue, parent)
             )

    assert {:ok, _} = CodingAgent.run_turn(session, "Read it", issue(), on_message: fn event -> send(parent, {:event, event}) end)

    assert_receive {:event, %{event: :tool_call, payload: %{name: "read_file"}}}
    assert_receive {:event, %{event: :tool_result, payload: %{success: true, output: "workspace evidence\n"}}}
    assert_receive {:request, _first}
    assert_receive {:request, second}
    assert Enum.any?(second.json["messages"], &(&1["role"] == "tool" and &1["content"] == "workspace evidence\n"))
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "does not execute plain-text tool syntax when the fallback quirk is disabled", %{workspace: workspace} do
    parent = self()

    fallback =
      response(%{
        "id" => "req-disabled-fallback",
        "choices" => [
          %{
            "finish_reason" => "stop",
            "message" => %{
              "role" => "assistant",
              "content" => ~s(<tool_call>{"name":"read_file","arguments":{"path":"sample.txt"}}</tool_call>)
            }
          }
        ]
      })

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance([]),
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: fn request ->
                 send(parent, {:request, request})
                 fallback
               end
             )

    assert {:ok, _} = CodingAgent.run_turn(session, "Read it", issue(), on_message: fn event -> send(parent, {:event, event}) end)
    assert_receive {:request, _request}
    refute_receive {:event, %{event: :tool_call}}
    refute_receive {:event, %{event: :tool_result}}
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "normalizes provider errors without retaining a credential", %{workspace: workspace} do
    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance([]),
               api_key_fetcher: fn _ -> "credential-that-must-not-leak" end,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 500,
                    body: %{"error" => %{"message" => "provider failed"}},
                    headers: %{}
                  }}
               end
             )

    assert {:error, {:http_error, 500, "provider failed"}} =
             CodingAgent.run_turn(session, "trigger failure", issue(), [])

    refute inspect(session) =~ "credential-that-must-not-leak"
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "Responses tool loops replay provider output items and function results", %{workspace: workspace} do
    parent = self()

    first =
      response(%{
        "id" => "resp-1",
        "model" => "deepseek-v4-flash",
        "status" => "completed",
        "output" => [
          %{"id" => "reasoning-1", "type" => "reasoning", "summary" => [%{"type" => "summary_text", "text" => "Inspect it."}]},
          %{"id" => "fc-1", "type" => "function_call", "call_id" => "call-1", "name" => "read_file", "arguments" => ~s({"path":"sample.txt"})}
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 4, "total_tokens" => 14}
      })

    final =
      response(%{
        "id" => "resp-2",
        "model" => "deepseek-v4-flash",
        "status" => "completed",
        "output" => [
          %{
            "id" => "message-1",
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => "Done."}]
          }
        ]
      })

    {:ok, queue} = Agent.start_link(fn -> [first, final] end)

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "deepseek",
               instance: %{instance([]) | transport: :responses},
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: queue_fun(queue, parent)
             )

    assert {:ok, _} = CodingAgent.run_turn(session, "Inspect", issue(), [])

    assert_receive {:request, %{url: "https://example.invalid/v1/responses"} = first_request}
    assert %{"type" => "function", "name" => "read_file", "parameters" => %{}} = hd(first_request.json["tools"])
    refute Map.has_key?(hd(first_request.json["tools"]), "function")
    assert_receive {:request, second}

    assert Enum.any?(second.json["input"], &(&1["type"] == "reasoning" and &1["id"] == "reasoning-1"))
    assert Enum.any?(second.json["input"], &(&1["type"] == "function_call" and &1["call_id"] == "call-1"))

    assert Enum.any?(
             second.json["input"],
             &(&1["type"] == "function_call_output" and &1["call_id"] == "call-1" and &1["output"] =~ "workspace evidence")
           )

    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "OpenRouter attributes usage to the selected endpoint and preserves cache hits", %{workspace: workspace} do
    parent = self()

    routed =
      response(%{
        "id" => "openrouter-1",
        "model" => "router/auto",
        "provider" => "OpenRouter",
        "openrouter_metadata" => %{
          "endpoints" => %{
            "available" => [
              %{"provider" => "Other", "model" => "other/model", "selected" => false},
              %{"provider" => "DeepSeek", "model" => "deepseek/deepseek-v4-flash", "selected" => true}
            ]
          }
        },
        "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Done."}}],
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 5,
          "total_tokens" => 105,
          "prompt_tokens_details" => %{"cached_tokens" => 80}
        }
      })

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "openrouter",
               instance: %{instance([]) | quirks: %{openrouter_metadata: true}},
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: fn request ->
                 send(parent, {:request, request})
                 routed
               end
             )

    assert {:ok, _} =
             CodingAgent.run_turn(session, "Route this", issue(), on_message: fn event -> send(parent, {:event, event}) end)

    assert_receive {:request, request}
    assert request.headers["x-openrouter-metadata"] == "enabled"

    assert_receive {:event,
                    %{
                      event: :usage,
                      model: "deepseek/deepseek-v4-flash",
                      provider: "DeepSeek",
                      upstream_provider: "DeepSeek",
                      payload: %{"upstream_provider" => "DeepSeek"},
                      usage: %{"prompt_tokens_details" => %{"cached_tokens" => 80}}
                    }}

    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "OpenRouter does not invent an upstream from ambiguous or malformed selections" do
    selections = [
      [
        %{"provider" => "DeepSeek", "selected" => true},
        %{"provider" => "Anthropic", "selected" => true}
      ],
      [%{"provider" => 42, "selected" => true}]
    ]

    for available <- selections do
      body = %{
        "id" => "openrouter-ambiguous",
        "model" => "router/auto",
        "provider" => "OpenRouter",
        "openrouter_metadata" => %{"endpoints" => %{"available" => available}},
        "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Done."}}],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
      }

      config = %{
        backend: :openrouter,
        base_url: "https://example.invalid/v1",
        api_key: "secret",
        model: "router/auto",
        provider: nil,
        transport: :chat_completions,
        quirks: %{local_concurrency_limit: false, openrouter_metadata: true},
        request_fun: fn _request -> response(body) end
      }

      assert {:ok, completion} = Transport.complete(config, [], [])
      assert completion.upstream_provider == nil
      assert completion.provider == "OpenRouter"
    end
  end

  test "OpenRouter preserves completions when endpoint metadata has the wrong shape" do
    cases = [
      {:chat_completions,
       %{
         "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Done."}}]
       }},
      {:responses,
       %{
         "status" => "completed",
         "output" => [
           %{
             "type" => "message",
             "role" => "assistant",
             "content" => [%{"type" => "output_text", "text" => "Done."}]
           }
         ]
       }}
    ]

    malformed_metadata = [
      "not-a-map",
      %{"endpoints" => "not-a-map"},
      %{"endpoints" => %{"available" => "not-a-list"}},
      %{"endpoints" => %{"available" => ["not-an-endpoint", 42]}}
    ]

    for {transport, transport_body} <- cases,
        metadata <- malformed_metadata do
      body =
        Map.merge(transport_body, %{
          "id" => "openrouter-malformed",
          "model" => "router/auto",
          "provider" => "OpenRouter",
          "openrouter_metadata" => metadata,
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
        })

      config = %{
        backend: :openrouter,
        base_url: "https://example.invalid/v1",
        api_key: "secret",
        model: "router/auto",
        provider: nil,
        transport: transport,
        quirks: %{local_concurrency_limit: false, openrouter_metadata: true},
        request_fun: fn _request -> response(body) end
      }

      assert {:ok, completion} = Transport.complete(config, [], [])
      assert completion.upstream_provider == nil
      assert completion.provider == "OpenRouter"
      assert completion.usage == %{"prompt_tokens" => 1, "completion_tokens" => 1}
    end
  end

  test "direct transports ignore OpenRouter endpoint metadata" do
    body = %{
      "id" => "direct-with-metadata",
      "model" => "deepseek-chat",
      "provider" => "DeepSeek",
      "openrouter_metadata" => %{
        "endpoints" => %{
          "available" => [%{"provider" => "InjectedRoute", "selected" => true}]
        }
      },
      "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Done."}}],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
    }

    config = %{
      backend: :deepseek,
      base_url: "https://example.invalid/v1",
      api_key: "secret",
      model: "deepseek-chat",
      provider: nil,
      transport: :chat_completions,
      quirks: %{local_concurrency_limit: false, openrouter_metadata: false},
      request_fun: fn _request -> response(body) end
    }

    assert {:ok, completion} = Transport.complete(config, [], [])
    assert completion.upstream_provider == nil
  end

  test "a message delivered at the completion checkpoint receives a provider response", %{workspace: workspace} do
    parent = self()

    first =
      response(%{
        "id" => "completion-before-message",
        "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Initial response."}}]
      })

    followup =
      response(%{
        "id" => "completion-after-message",
        "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Operator message answered."}}]
      })

    {:ok, queue} = Agent.start_link(fn -> [first, followup] end)

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance([]),
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: queue_fun(queue, parent)
             )

    checkpoint = fn
      %{kind: :notification} ->
        if Process.get(:completion_message_delivered) do
          :noop
        else
          Process.put(:completion_message_delivered, true)
          {:deliver_text, "Late operator message", fn metadata -> send(parent, {:delivered, metadata}) end, fn _ -> :ok end}
        end

      _ ->
        :noop
    end

    assert {:ok, _} =
             CodingAgent.run_turn(session, "Start", issue(),
               on_safe_checkpoint: checkpoint,
               on_message: fn event -> send(parent, {:event, event}) end
             )

    assert_receive {:request, _first}
    assert_receive {:request, second}
    assert List.last(second.json["messages"])["content"] == "Late operator message"
    assert_receive {:event, %{event: :assistant, payload: %{text: "Operator message answered."}}}
    assert_receive {:delivered, %{checkpoint: :notification}}

    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "a queued-message notification cannot hide a pending pause", %{workspace: workspace} do
    parent = self()

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance([]),
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: fn request ->
                 send(parent, {:unexpected_request, request})
                 {:error, :unexpected_request}
               end
             )

    send(self(), {:agent_queue_updated, "1440", 1, false})
    send(self(), {:pause_agent, 42, 3})

    assert {:paused, %{reason: :operator_pause, request_id: 42, generation: 3}} =
             CodingAgent.run_turn(session, "Start", issue(), [])

    refute_receive {:unexpected_request, _request}
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "a pause requested inside a tool batch waits until every advertised call has a result", %{
    workspace: workspace
  } do
    parent = self()

    first =
      response(%{
        "id" => "req-tool-batch",
        "choices" => [
          %{
            "finish_reason" => "tool_calls",
            "message" => %{
              "role" => "assistant",
              "tool_calls" =>
                Enum.map(1..2, fn index ->
                  %{
                    "id" => "call-#{index}",
                    "type" => "function",
                    "function" => %{"name" => "read_file", "arguments" => ~s({"path":"sample.txt"})}
                  }
                end)
            }
          }
        ]
      })

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance([]),
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: fn _request -> first end
             )

    checkpoint = fn
      %{kind: :tool_result} ->
        unless Process.get(:pause_sent) do
          Process.put(:pause_sent, true)
          send(self(), {:pause_agent, 42, 3})
        end

        :noop

      _ ->
        :noop
    end

    assert {:paused, %{reason: :operator_pause, request_id: 42, generation: 3}} =
             CodingAgent.run_turn(session, "Read twice", issue(),
               on_safe_checkpoint: checkpoint,
               on_message: fn event -> send(parent, {:event, event}) end
             )

    assert_receive {:event, %{event: :tool_result, payload: %{id: "call-1", success: true}}}
    assert_receive {:event, %{event: :tool_result, payload: %{id: "call-2", success: true}}}
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "checkpoint messages follow every result in a multi-tool batch", %{
    workspace: workspace
  } do
    parent = self()

    first =
      response(%{
        "id" => "req-ordered-batch",
        "choices" => [
          %{
            "finish_reason" => "tool_calls",
            "message" => %{
              "role" => "assistant",
              "tool_calls" =>
                Enum.map(1..2, fn index ->
                  %{
                    "id" => "ordered-#{index}",
                    "type" => "function",
                    "function" => %{
                      "name" => "read_file",
                      "arguments" => ~s({"path":"sample.txt"})
                    }
                  }
                end)
            }
          }
        ]
      })

    final =
      response(%{
        "id" => "req-ordered-final",
        "choices" => [
          %{
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "Done."}
          }
        ]
      })

    {:ok, queue} = Agent.start_link(fn -> [first, final] end)

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance([]),
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: queue_fun(queue, parent)
             )

    checkpoint = fn
      %{kind: :tool_result} ->
        if Process.get(:batch_message_delivered) do
          :noop
        else
          Process.put(:batch_message_delivered, true)
          {:deliver_text, "After the batch", fn _metadata -> :ok end, fn _reason -> :ok end}
        end

      _ ->
        :noop
    end

    assert {:ok, _session} =
             CodingAgent.run_turn(session, "Read twice", issue(), on_safe_checkpoint: checkpoint)

    assert_receive {:request, _first_request}
    assert_receive {:request, second_request}

    assert Enum.map(Enum.take(second_request.json["messages"], -3), fn message ->
             {message["role"], message["tool_call_id"], message["content"]}
           end) == [
             {"tool", "ordered-1", "workspace evidence\n"},
             {"tool", "ordered-2", "workspace evidence\n"},
             {"user", nil, "After the batch"}
           ]

    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "rejects incomplete Responses and token-limited chat completions", %{workspace: workspace} do
    cases = [
      {:responses,
       %{
         "id" => "resp-incomplete",
         "status" => "incomplete",
         "output" => [],
         "incomplete_details" => %{"reason" => "max_output_tokens"}
       }, {:incomplete_provider_response, "incomplete"}},
      {:chat_completions,
       %{
         "id" => "chat-limited",
         "choices" => [
           %{
             "finish_reason" => "length",
             "message" => %{"role" => "assistant", "content" => "partial"}
           }
         ]
       }, {:incomplete_provider_response, "length"}}
    ]

    for {transport, body, reason} <- cases do
      assert {:ok, session} =
               CodingAgent.start_session(workspace,
                 backend: "deepseek",
                 instance: %{instance([]) | transport: transport},
                 api_key_fetcher: fn _ -> "secret" end,
                 request_fun: fn _request -> response(body) end
               )

      assert {:error, ^reason} = CodingAgent.run_turn(session, "Finish fully", issue(), [])
      assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
    end
  end

  test "OpenRouter requires an explicit underlying model", %{workspace: workspace} do
    assert {:error, :missing_model} =
             CodingAgent.start_session(workspace,
               backend: "openrouter",
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: fn _request -> flunk("request must not run") end
             )
  end

  test "session startup rejects the workspace root, outside paths, and symlink escapes" do
    root =
      Path.join(
        System.tmp_dir!(),
        "aiur-openai-root-#{System.unique_integer([:positive])}"
      )

    outside =
      Path.join(
        System.tmp_dir!(),
        "aiur-openai-outside-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(root, "escaped"))
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> File.rm_rf!(outside) end)

    opts = [
      backend: "kimi",
      instance: instance([]),
      workspace_root: root,
      api_key_fetcher: fn _ -> "secret" end
    ]

    assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
             CodingAgent.start_session(root, opts)

    assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
             CodingAgent.start_session(outside, opts)

    assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
             CodingAgent.start_session(Path.join(root, "escaped"), opts)
  end

  test "backend config failures remain visible", %{workspace: workspace} do
    assert {:error, {:backend_config_unavailable, "configuration unavailable"}} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance([]),
               backend_config_fetcher: fn _backend ->
                 raise "configuration unavailable"
               end,
               api_key_fetcher: fn _ -> "secret" end
             )
  end

  test "continues a long tool loop past the former 32-round cap and completes the turn", %{workspace: workspace} do
    parent = self()

    # Well above the old 32-round cap, comfortably below the 256-round budget.
    rounds = 40

    tool_responses =
      for round <- 1..rounds do
        response(%{
          "id" => "req-long-#{round}",
          "choices" => [
            %{
              "finish_reason" => "tool_calls",
              "message" => %{
                "role" => "assistant",
                "tool_calls" => [
                  %{
                    "id" => "call-long-#{round}",
                    "type" => "function",
                    "function" => %{"name" => "read_file", "arguments" => ~s({"path":"sample.txt"})}
                  }
                ]
              }
            }
          ]
        })
      end

    final =
      response(%{
        "id" => "req-long-final",
        "choices" => [
          %{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Done after many rounds."}}
        ]
      })

    {:ok, queue} = Agent.start_link(fn -> tool_responses ++ [final] end)

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance([]),
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: queue_fun(queue, parent)
             )

    assert {:ok, %{result: :turn_completed}} =
             CodingAgent.run_turn(session, "Work through many rounds", issue(), [])

    assert length(collect_requests(rounds + 1)) == rounds + 1
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "ends an endless tool loop only at the raised round bound", %{workspace: workspace} do
    parent = self()

    responses =
      for round <- 1..@max_tool_rounds do
        response(%{
          "id" => "req-bound-#{round}",
          "choices" => [
            %{
              "finish_reason" => "tool_calls",
              "message" => %{
                "role" => "assistant",
                "tool_calls" => [
                  %{
                    "id" => "call-bound-#{round}",
                    "type" => "function",
                    "function" => %{"name" => "read_file", "arguments" => ~s({"path":"sample.txt"})}
                  }
                ]
              }
            }
          ]
        })
      end

    {:ok, queue} = Agent.start_link(fn -> responses end)

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance([]),
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: queue_fun(queue, parent)
             )

    assert {:error, :tool_round_limit_exceeded} =
             CodingAgent.run_turn(session, "Loop forever", issue(), [])

    # Exactly one request per allowed round and none for the round that trips
    # the guard — a regression back toward 32 would fail this count.
    assert length(collect_requests(@max_tool_rounds)) == @max_tool_rounds
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  defp instance(extra) do
    %{
      base_url: "https://example.invalid/v1",
      api_key_env: "TEST_KEY",
      default_model: "deepseek-v4-flash",
      transport: :chat_completions,
      quirks: Map.new(extra)
    }
  end

  defp response(body), do: {:ok, %{status: 200, body: body, headers: %{}}}

  defp queue_fun(queue, parent) do
    fn request ->
      send(parent, {:request, request})

      Agent.get_and_update(queue, fn
        [next | rest] -> {next, rest}
        [] -> {{:error, :unexpected_request}, []}
      end)
    end
  end

  defp collect_requests(count) do
    Enum.reduce(1..count, [], fn _, acc ->
      receive do
        {:request, request} -> [request | acc]
      after
        1_000 -> flunk("expected #{count} requests, received #{length(acc)}")
      end
    end)
    |> Enum.reverse()
  end

  defp issue, do: %Issue{id: "1440", identifier: "1440", title: "compat test", labels: []}
end
