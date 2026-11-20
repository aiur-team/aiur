defmodule Aiur.Config.Schema.OpenRouterBackendTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema.OpenRouterBackend

  describe "validate/1" do
    test "accepts every documented provider field" do
      assert :ok =
               OpenRouterBackend.validate(%{
                 "provider" => %{
                   "order" => ["Anthropic", "Together AI"],
                   "only" => ["Anthropic"],
                   "ignore" => ["Azure"],
                   "allow_fallbacks" => false,
                   "sort" => "price",
                   "max_price" => %{"prompt" => 1.5, "completion" => 6},
                   "quantizations" => ["fp8", "int8"],
                   "data_collection" => "deny",
                   "require_parameters" => true
                 }
               })
    end

    test "accepts an empty or absent block, so OpenRouter's own default routing applies" do
      assert :ok = OpenRouterBackend.validate(%{})
      assert :ok = OpenRouterBackend.validate(%{"provider" => %{}})
      assert :ok = OpenRouterBackend.validate(%{"provider" => nil})
    end

    test "ignores the generic backend keys it does not own" do
      assert :ok = OpenRouterBackend.validate(%{"base_url" => "https://example.invalid", "model" => "vendor/model", "enabled" => true})
    end

    test "rejects an unknown provider field and names the allowed ones" do
      assert {:error, message} = OpenRouterBackend.validate(%{"provider" => %{"max_tokens" => 10}})
      assert message =~ "provider has an unknown field \"max_tokens\""
      assert message =~ "allow_fallbacks"
      assert message =~ "require_parameters"
    end

    test "rejects malformed provider values" do
      cases = [
        {%{"order" => "Anthropic"}, "provider.order must be a list of strings"},
        {%{"only" => []}, "provider.only must be a list of strings"},
        {%{"ignore" => [""]}, "provider.ignore must be a list of non-blank strings"},
        {%{"quantizations" => [1]}, "provider.quantizations must be a list of non-blank strings"},
        {%{"allow_fallbacks" => "false"}, "provider.allow_fallbacks must be true or false"},
        {%{"require_parameters" => "yes"}, "provider.require_parameters must be true or false"},
        {%{"sort" => "cheapest"}, "provider.sort must be one of price, throughput, latency"},
        {%{"data_collection" => "maybe"}, "provider.data_collection must be one of allow, deny"},
        {%{"max_price" => 5}, "provider.max_price must be a map with prompt and/or completion prices"},
        {%{"max_price" => %{"prompt" => -1}}, "provider.max_price.prompt must be a non-negative price per million tokens"},
        {%{"max_price" => %{"input" => 1}}, "provider.max_price has an unknown field \"input\"; allowed fields: prompt, completion"}
      ]

      for {provider, expected} <- cases do
        assert {:error, message} = OpenRouterBackend.validate(%{"provider" => provider}), "expected #{inspect(provider)} to fail"
        assert message == expected
      end
    end

    test "validates named model sets and their per-route provider overrides" do
      assert :ok =
               OpenRouterBackend.validate(%{
                 "routes" => %{
                   "cheap" => %{
                     "models" => ["deepseek/deepseek-v4-flash", "moonshotai/kimi-k2.7-code"],
                     "provider" => %{"sort" => "price"}
                   }
                 }
               })

      assert {:error, message} = OpenRouterBackend.validate(%{"routes" => %{"cheap" => %{"models" => []}}})
      assert message =~ "routes.cheap.models must be a non-empty list"

      assert {:error, message} = OpenRouterBackend.validate(%{"routes" => %{"cheap" => %{"model" => "vendor/a"}}})
      assert message =~ "routes.cheap has an unknown field \"model\""

      assert {:error, message} = OpenRouterBackend.validate(%{"routes" => %{"cheap" => "vendor/a"}})
      assert message =~ "routes.cheap must be a map"

      assert {:error, message} = OpenRouterBackend.validate(%{"routes" => %{"a:b" => %{"models" => ["vendor/a"]}}})
      assert message =~ "cannot be written as a route"

      assert {:error, message} = OpenRouterBackend.validate(%{"routes" => %{"cheap+remote" => %{"models" => ["vendor/a"]}}})
      assert message =~ "+remote"

      assert {:error, message} = OpenRouterBackend.validate(%{"routes" => %{"cheap" => %{"provider" => %{"order" => "Anthropic"}}}})
      assert message == "routes.cheap.provider.order must be a list of strings"
    end
  end

  describe "apply_route/2" do
    test "leaves a single-model route with no settings untouched" do
      config = %{model: "vendor/model", backend: "openrouter"}

      assert OpenRouterBackend.apply_route(config, "vendor/model") == %{model: "vendor/model", backend: "openrouter"}
    end

    test "expands an inline set and defaults to price sorting" do
      config = %{model: "{vendor/a, vendor/b}"}

      routed = OpenRouterBackend.apply_route(config, "{vendor/a, vendor/b}")

      assert routed.model == "vendor/a"
      assert routed.models == ["vendor/a", "vendor/b"]
      assert routed.provider == %{"sort" => "price"}
    end

    test "expands a named set and layers the route provider over the backend provider" do
      config = %{
        model: "cheap",
        provider: %{"allow_fallbacks" => true},
        routes: %{"cheap" => %{"models" => ["vendor/a", "vendor/b"], "provider" => %{"only" => ["VendorA"]}}}
      }

      routed = OpenRouterBackend.apply_route(config, "cheap")

      assert routed.model == "vendor/a"
      assert routed.models == ["vendor/a", "vendor/b"]
      assert routed.provider == %{"allow_fallbacks" => true, "only" => ["VendorA"], "sort" => "price"}
    end

    test "keeps an operator's order instead of adding the price default" do
      config = %{provider: %{"order" => ["VendorA"]}}

      routed = OpenRouterBackend.apply_route(config, "{vendor/a, vendor/b}")

      assert routed.provider == %{"order" => ["VendorA"]}
      assert routed.models == ["vendor/a", "vendor/b"]
    end

    test "recognises a configured route name" do
      config = %{"routes" => %{"cheap" => %{"models" => ["vendor/a"]}}}

      assert OpenRouterBackend.named_route?(config, "cheap")
      refute OpenRouterBackend.named_route?(config, "vendor/a")
      refute OpenRouterBackend.named_route?(%{}, "cheap")
      refute OpenRouterBackend.named_route?(config, nil)
    end

    test "sends nothing when neither the backend nor the route configures a provider" do
      routed = OpenRouterBackend.apply_route(%{model: "vendor/model"}, "vendor/model")

      refute Map.has_key?(routed, :provider)
      refute Map.has_key?(routed, :models)
    end
  end
end
