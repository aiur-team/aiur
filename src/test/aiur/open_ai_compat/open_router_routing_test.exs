defmodule Aiur.OpenAICompat.OpenRouterRoutingTest do
  use ExUnit.Case, async: true
  use Aiur.TestSupport.OpenAICompatAgent

  alias Aiur.Config.RoutingValue
  alias Aiur.OpenAICompat.CodingAgent

  # The routing fields OpenRouter documents. aiur forwards them as given so the
  # operator can pin upstreams, or hand model and upstream choice to OpenRouter.
  describe "provider preferences on the request" do
    test "a pinned route forwards order, only, ignore and allow_fallbacks", %{workspace: workspace} do
      request =
        routed_request(workspace,
          model: "anthropic/claude-sonnet-5",
          backend_config: %{
            "provider" => %{
              "order" => ["Anthropic", "Together AI"],
              "only" => ["Anthropic", "Together AI"],
              "ignore" => ["Azure"],
              "allow_fallbacks" => false
            }
          }
        )

      assert request.json["model"] == "anthropic/claude-sonnet-5"
      assert request.json["provider"] == %{"order" => ["Anthropic", "Together AI"], "only" => ["Anthropic", "Together AI"], "ignore" => ["Azure"], "allow_fallbacks" => false}
      refute Map.has_key?(request.json, "models")
    end

    test "sort price with no order is the cheapest-available handoff", %{workspace: workspace} do
      request = routed_request(workspace, model: "deepseek/deepseek-v4-flash", backend_config: %{"provider" => %{"sort" => "price"}})

      assert request.json["provider"] == %{"sort" => "price"}
      refute Map.has_key?(request.json, "provider.order")
    end

    test "max_price forwards a per-million-token cap", %{workspace: workspace} do
      request =
        routed_request(workspace,
          model: "deepseek/deepseek-v4-flash",
          backend_config: %{"provider" => %{"max_price" => %{"prompt" => 0.5, "completion" => 1.25}}}
        )

      assert request.json["provider"]["max_price"] == %{"prompt" => 0.5, "completion" => 1.25}
    end

    test "an operator who configures nothing sends no provider block", %{workspace: workspace} do
      request = routed_request(workspace, model: "deepseek/deepseek-v4-flash")

      refute Map.has_key?(request.json, "provider")
      refute Map.has_key?(request.json, "models")
    end
  end

  describe "model sets" do
    test "an inline set is sent as a models list the operator's way", %{workspace: workspace} do
      request =
        routed_request(workspace,
          model: "{deepseek/deepseek-v4.1-flash-1017, deepseek/deepseek-v4-flash}"
        )

      assert request.json["model"] == "deepseek/deepseek-v4.1-flash-1017"
      assert request.json["models"] == ["deepseek/deepseek-v4.1-flash-1017", "deepseek/deepseek-v4-flash"]
      assert request.json["provider"] == %{"sort" => "price"}
    end

    test "a named set expands from config and keeps the operator's ranking", %{workspace: workspace} do
      request =
        routed_request(workspace,
          model: "cheap",
          backend_config: %{
            "routes" => %{
              "cheap" => %{
                "models" => ["deepseek/deepseek-v4-flash", "moonshotai/kimi-k2.7-code"],
                "provider" => %{"quantizations" => ["fp8"]}
              }
            }
          }
        )

      assert request.json["model"] == "deepseek/deepseek-v4-flash"
      assert request.json["models"] == ["deepseek/deepseek-v4-flash", "moonshotai/kimi-k2.7-code"]
      assert request.json["provider"] == %{"quantizations" => ["fp8"], "sort" => "price"}
    end

    test "a set with a pinned order keeps that order instead of price sorting", %{workspace: workspace} do
      request =
        routed_request(workspace,
          model: "{anthropic/claude-sonnet-5, anthropic/claude-opus-5}",
          backend_config: %{"provider" => %{"order" => ["Anthropic"]}}
        )

      assert request.json["models"] == ["anthropic/claude-sonnet-5", "anthropic/claude-opus-5"]
      assert request.json["provider"] == %{"order" => ["Anthropic"]}
    end

    test "cost accounting records the served model and provider, not the configured set", %{workspace: workspace} do
      parent = self()

      body = %{
        "id" => "openrouter-set-1",
        "model" => "moonshotai/kimi-k2.7-code",
        "provider" => "OpenRouter",
        "openrouter_metadata" => %{
          "endpoints" => %{"available" => [%{"provider" => "Moonshot", "model" => "moonshotai/kimi-k2.7-code", "selected" => true}]}
        },
        "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Done."}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2, "total_tokens" => 12}
      }

      assert {:ok, session} =
               CodingAgent.start_session(workspace,
                 backend: "openrouter",
                 model: "{deepseek/deepseek-v4-flash, moonshotai/kimi-k2.7-code}",
                 api_key_fetcher: fn _ -> "secret" end,
                 request_fun: fn _request -> response(body) end
               )

      assert {:ok, _} =
               CodingAgent.run_turn(session, "Go", issue(), on_message: fn event -> send(parent, {:event, event}) end)

      assert_receive {:event, %{event: :usage, model: "moonshotai/kimi-k2.7-code", provider: "Moonshot", upstream_provider: "Moonshot"}}, 1_000

      assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
    end
  end

  describe "per-route overrides" do
    test "one route stays pinned while another is handed off", %{workspace: workspace} do
      config = %{
        "provider" => %{"sort" => "price"},
        "routes" => %{"anthropic/claude-sonnet-5" => %{"provider" => %{"only" => ["Anthropic"], "allow_fallbacks" => false}}}
      }

      pinned = routed_request(workspace, model: "anthropic/claude-sonnet-5", backend_config: config)
      assert pinned.json["provider"] == %{"sort" => "price", "only" => ["Anthropic"], "allow_fallbacks" => false}
      refute Map.has_key?(pinned.json, "models")

      handed_off = routed_request(workspace, model: "deepseek/deepseek-v4-flash", backend_config: config)
      assert handed_off.json["provider"] == %{"sort" => "price"}
    end
  end

  describe "route grammar" do
    test "a set carries its models and a plain model is not a set" do
      assert RoutingValue.model_set("{vendor/a, vendor/b}") == {:ok, ["vendor/a", "vendor/b"]}
      assert RoutingValue.model_set("{vendor/a}") == {:ok, ["vendor/a"]}
      assert RoutingValue.model_set("vendor/a") == :error
      assert RoutingValue.model_set("{}") == :error
      assert RoutingValue.model_set("{vendor/a,}") == :error
      assert RoutingValue.model_set("{vendor/a, {vendor/b}}") == :error
      assert RoutingValue.model_set?("{vendor/a, vendor/b}") == true
      refute RoutingValue.model_set?("vendor/a")
    end
  end

  # A session started on the real OpenRouter registry entry, so the request the
  # transport builds is the one production would build.
  defp routed_request(workspace, opts) do
    parent = self()

    body = %{
      "id" => "openrouter-routing",
      "model" => Keyword.get(opts, :model, "deepseek/deepseek-v4-flash"),
      "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Done."}}],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
    }

    start_opts =
      [
        backend: "openrouter",
        model: Keyword.fetch!(opts, :model),
        api_key_fetcher: fn _ -> "secret" end,
        request_fun: fn request ->
          send(parent, {:request, request})
          response(body)
        end
      ]
      |> maybe_put_backend_config(Keyword.get(opts, :backend_config))

    assert {:ok, session} = CodingAgent.start_session(workspace, start_opts)
    assert {:ok, _} = CodingAgent.run_turn(session, "Go", issue(), [])
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)

    assert_receive {:request, request}, 1_000
    request
  end

  defp maybe_put_backend_config(opts, nil), do: opts
  defp maybe_put_backend_config(opts, config), do: Keyword.put(opts, :backend_config, config)
end
