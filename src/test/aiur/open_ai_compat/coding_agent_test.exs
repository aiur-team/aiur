defmodule Aiur.OpenAICompat.CodingAgentTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.OpenAICompat.CodingAgent

  setup do
    workspace = Path.join(System.tmp_dir!(), "aiur-openai-compat-#{System.unique_integer([:positive])}")
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
                      usage: %{"prompt_tokens_details" => %{"cached_tokens" => 80}}
                    }}

    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
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

  defp issue, do: %Issue{id: "1440", identifier: "1440", title: "compat test", labels: []}
end
