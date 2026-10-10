defmodule Aiur.OpenAICompat.CodingAgentToolLoopTest do
  use ExUnit.Case, async: true
  use Aiur.TestSupport.OpenAICompatAgent

  alias Aiur.OpenAICompat.CodingAgent

  # Mirrors CodingAgent's per-turn tool-round budget; pinned so the
  # round-count assertions below fail if the bound ever drifts back down.
  @max_tool_rounds 256

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

    assert_receive {:request, first}, 1000
    assert first.url == "https://example.invalid/v1/chat/completions"
    assert first.headers["authorization"] == "Bearer super-secret"
    assert get_in(first.json, ["messages", Access.at(0), "content"]) == "Inspect the workspace"

    assert_receive {:request, second}, 1000
    messages = second.json["messages"]
    assistant = Enum.find(messages, &(&1["role"] == "assistant"))
    assert assistant["reasoning_content"] == "I should inspect the workspace."
    assert Enum.any?(messages, &(&1["role"] == "tool" and &1["content"] =~ "workspace evidence"))
    assert Enum.any?(messages, &(&1["role"] == "user" and &1["content"] == "Operator note"))

    assert_receive {:delivered, %{backend: "kimi", checkpoint: :tool_result}}, 1000
    refute_receive {:delivery_failed, _}, 100

    assert_receive {:event, %{event: :reasoning, payload: %{text: "I should inspect the workspace."}}}, 1000
    assert_receive {:event, %{event: :tool_call, payload: %{name: "read_file"}}}, 1000
    assert_receive {:event, %{event: :tool_result, payload: %{output: output}}}, 1000
    assert output =~ "workspace evidence"
    assert_receive {:event, %{event: :assistant, payload: %{text: "The workspace contains the expected evidence."}}}, 1000
    assert_receive {:event, %{event: :usage, usage: %{"total_tokens" => 48}}}, 1000

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

    assert_receive {:event, %{event: :tool_result, payload: %{success: false, output: output}}}, 1000
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

    assert_receive {:event, %{event: :tool_call, payload: %{name: "read_file"}}}, 1000
    assert_receive {:event, %{event: :tool_result, payload: %{success: true, output: "workspace evidence\n"}}}, 1000
    assert_receive {:request, _first}, 1000
    assert_receive {:request, second}, 1000
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
    assert_receive {:request, _request}, 1000
    refute_receive {:event, %{event: :tool_call}}, 100
    refute_receive {:event, %{event: :tool_result}}, 100
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

    assert_receive {:request, %{url: "https://example.invalid/v1/responses"} = first_request}, 1000
    assert %{"type" => "function", "name" => "read_file", "parameters" => %{}} = hd(first_request.json["tools"])
    refute Map.has_key?(hd(first_request.json["tools"]), "function")
    assert_receive {:request, second}, 1000

    assert Enum.any?(second.json["input"], &(&1["type"] == "reasoning" and &1["id"] == "reasoning-1"))
    assert Enum.any?(second.json["input"], &(&1["type"] == "function_call" and &1["call_id"] == "call-1"))

    assert Enum.any?(
             second.json["input"],
             &(&1["type"] == "function_call_output" and &1["call_id"] == "call-1" and &1["output"] =~ "workspace evidence")
           )

    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
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
end
