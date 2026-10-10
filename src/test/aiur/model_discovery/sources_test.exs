defmodule Aiur.ModelDiscovery.SourcesTest do
  use ExUnit.Case, async: true

  alias Aiur.CodingAgent
  alias Aiur.ModelDiscovery
  alias Aiur.ModelDiscovery.Source

  @openrouter_instance %{base_url: "https://openrouter.ai/api/v1", api_key_env: "OPENROUTER_API_KEY"}
  @deepseek_instance %{base_url: "https://api.deepseek.com", api_key_env: "DEEPSEEK_API_KEY"}
  @anthropic_instance %{base_url: "https://api.anthropic.com/v1", api_key_env: "ANTHROPIC_API_KEY"}

  setup context do
    dir = Aiur.TestSupport.tmp_root!("aiur-model-discovery-#{:erlang.phash2(context.test)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, cache: Path.join(dir, "model-catalog.json")}
  end

  describe "adapter selection is registry data, not a case statement" do
    test "every OpenAI-compatible backend names the source that matches its wire shape" do
      assert source("openrouter") == Source.OpenRouter
      assert source("deepseek") == Source.OpenAI
      assert source("kimi") == Source.OpenAI

      assert ModelDiscovery.discoverable?("openrouter")
      assert ModelDiscovery.discoverable?("kimi")
    end

    test "a backend with neither an HTTP catalogue nor a CLI catalogue is not discoverable" do
      refute ModelDiscovery.discoverable?("nope")

      assert ModelDiscovery.refresh("nope", fetch: &never_fetch/1) ==
               {:error, {:model_discovery_unsupported, "nope"}}
    end
  end

  describe "Source.OpenAI — identifiers only (OpenAI, DeepSeek, Moonshot)" do
    test "builds a bearer request against the instance base url" do
      assert {:ok, request} = Source.OpenAI.request(@deepseek_instance, "sk-test")
      assert request.url == "https://api.deepseek.com/models"
      assert request.headers == [{"authorization", "Bearer sk-test"}]
    end

    test "an absent key is a named error, not a crash — these catalogues require auth" do
      assert Source.OpenAI.request(@deepseek_instance, nil) == {:error, {:missing_api_key, "DEEPSEEK_API_KEY"}}
      assert Source.OpenAI.request(@deepseek_instance, "") == {:error, {:missing_api_key, "DEEPSEEK_API_KEY"}}
    end

    test "reads ids and reports no pricing, because the endpoint carries none" do
      body = %{"object" => "list", "data" => [%{"id" => "deepseek-v4-flash"}, %{"id" => "deepseek-reasoner"}]}

      assert {:ok, models} = Source.OpenAI.parse(body)
      assert Enum.map(models, & &1.id) == ["deepseek-v4-flash", "deepseek-reasoner"]
      refute Enum.any?(models, &Map.has_key?(&1, :pricing))
    end

    test "an unrecognized shape is an error, never an empty catalogue" do
      assert {:error, {:unexpected_model_list, Source.OpenAI}} = Source.OpenAI.parse(%{"models" => []})
    end
  end

  describe "Source.Anthropic — identifiers and display names, no pricing" do
    test "sends x-api-key and a pinned anthropic-version" do
      assert {:ok, request} = Source.Anthropic.request(@anthropic_instance, "sk-ant")
      assert request.url == "https://api.anthropic.com/v1/models"
      assert {"x-api-key", "sk-ant"} in request.headers
      assert {"anthropic-version", "2023-06-01"} in request.headers
    end

    test "requires a key and keeps display names" do
      assert Source.Anthropic.request(@anthropic_instance, nil) == {:error, {:missing_api_key, "ANTHROPIC_API_KEY"}}

      body = %{"data" => [%{"id" => "claude-opus-4-8", "display_name" => "Claude Opus 4.8", "type" => "model"}]}
      assert {:ok, [model]} = Source.Anthropic.parse(body)
      assert model == %{id: "claude-opus-4-8", display_name: "Claude Opus 4.8"}
    end
  end

  describe "Source.OpenRouter — the one catalogue that needs no key and quotes prices" do
    test "requests without a credential, and attributes the request when one exists" do
      assert {:ok, anonymous} = Source.OpenRouter.request(@openrouter_instance, nil)
      assert anonymous.url == "https://openrouter.ai/api/v1/models"
      assert anonymous.headers == []

      assert {:ok, keyed} = Source.OpenRouter.request(@openrouter_instance, "sk-or")
      assert keyed.headers == [{"authorization", "Bearer sk-or"}]
    end

    test "converts per-token USD strings to major units per million tokens" do
      assert {:ok, [model]} = Source.OpenRouter.parse(openrouter_body([sonnet()]))

      assert model.id == "anthropic/claude-sonnet-5"
      assert model.display_name == "Anthropic: Claude Sonnet 5"
      assert model.context_length == 1_000_000
      assert Decimal.equal?(model.pricing.input, Decimal.new("2"))
      assert Decimal.equal?(model.pricing.output, Decimal.new("10"))
      assert Decimal.equal?(model.pricing.cached_input, Decimal.new("0.2"))
    end

    test "a free model keeps its real zero; an unquotable price is simply absent" do
      free = %{"id" => "vendor/free-model", "pricing" => %{"prompt" => "0", "completion" => "0"}}
      opaque = %{"id" => "vendor/opaque-model", "pricing" => %{"prompt" => "variable", "completion" => "-1"}}

      assert {:ok, [priced, unpriced]} = Source.OpenRouter.parse(openrouter_body([free, opaque]))
      assert Decimal.equal?(priced.pricing.input, Decimal.new(0))
      refute Map.has_key?(unpriced, :pricing)
    end
  end

  describe "ingest refuses identifiers aiur cannot address" do
    test "a `:` in the id is fatal, because routing values split on it", %{cache: cache} do
      body = openrouter_body([sonnet(), batch_variant(), unstable_pointer()])

      assert {:ok, result} = refresh(body, path: cache)
      assert Enum.map(result.models, &Map.get(&1, "id")) == ["anthropic/claude-sonnet-5"]

      reasons = Map.new(result.rejected, &{&1["id"], &1["reason"]})
      assert reasons["moonshotai/kimi-k2.7-code:batch"] == "reserved_routing_separator"
      assert reasons["~moonshotai/kimi-latest"] == "unstable_identifier_prefix"
    end

    test "a refused identifier never reaches the usable set", %{cache: cache} do
      assert {:ok, _result} = refresh(openrouter_body([batch_variant(), unstable_pointer()]), path: cache)

      assert ModelDiscovery.cached_models("openrouter", path: cache) == []
      refute "moonshotai/kimi-k2.7-code:batch" in ModelDiscovery.models_for("openrouter", path: cache, refresh: false)
      refute "~moonshotai/kimi-latest" in ModelDiscovery.models_for("openrouter", path: cache, refresh: false)
      assert length(ModelDiscovery.rejected("openrouter", path: cache)) == 2
    end
  end

  defp source(backend), do: get_in(CodingAgent.backends(), [backend, :openai_compat, :models_endpoint])

  defp refresh(body, opts) do
    ModelDiscovery.refresh("openrouter", Keyword.put(opts, :fetch, fn _request -> {:ok, %{status: 200, body: body}} end))
  end

  defp never_fetch(_request), do: flunk("model discovery made a request when it must not have")

  defp openrouter_body(models), do: %{"data" => models}

  defp sonnet do
    %{
      "id" => "anthropic/claude-sonnet-5",
      "canonical_slug" => "anthropic/claude-sonnet-5",
      "name" => "Anthropic: Claude Sonnet 5",
      "context_length" => 1_000_000,
      "pricing" => %{
        "prompt" => "0.000002",
        "completion" => "0.00001",
        "input_cache_read" => "0.0000002",
        "request" => "0"
      }
    }
  end

  defp batch_variant do
    %{"id" => "moonshotai/kimi-k2.7-code:batch", "name" => "Kimi K2.7 Code (batch)"}
  end

  defp unstable_pointer, do: %{"id" => "~moonshotai/kimi-latest", "name" => "Kimi (latest)"}
end
