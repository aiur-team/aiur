defmodule Aiur.OpenAICompat.CodingAgentOpenRouterTest do
  use ExUnit.Case, async: true
  use Aiur.TestSupport.OpenAICompatAgent

  alias Aiur.OpenAICompat.{CodingAgent, Transport}

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

    assert_receive {:request, request}, 1000
    assert request.headers["x-openrouter-metadata"] == "enabled"

    assert_receive {:event,
                    %{
                      event: :usage,
                      model: "deepseek/deepseek-v4-flash",
                      provider: "DeepSeek",
                      upstream_provider: "DeepSeek",
                      payload: %{"upstream_provider" => "DeepSeek"},
                      usage: %{"prompt_tokens_details" => %{"cached_tokens" => 80}}
                    }},
                   1000

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

  test "OpenRouter requires an explicit underlying model", %{workspace: workspace} do
    assert {:error, :missing_model} =
             CodingAgent.start_session(workspace,
               backend: "openrouter",
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: fn _request -> flunk("request must not run") end
             )
  end
end
