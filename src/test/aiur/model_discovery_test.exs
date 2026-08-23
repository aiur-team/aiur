Code.require_file("usage/pricing_fixture.exs", __DIR__)

defmodule Aiur.ModelDiscoveryTest do
  use ExUnit.Case, async: true

  alias Aiur.CodingAgent
  alias Aiur.Config.Schema
  alias Aiur.ModelDiscovery
  alias Aiur.ModelDiscovery.Source
  alias Aiur.Usage.{PriceTable, Pricing, PricingFixture}

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

    test "a backend with no catalogue endpoint is simply not discoverable" do
      # codex and claude answer `model/list` over their own CLI transport
      # (`Aiur.ModelCatalog`); they declare no HTTP catalogue and must not be
      # given one implicitly.
      refute ModelDiscovery.discoverable?("codex")
      refute ModelDiscovery.discoverable?("claude")
      refute ModelDiscovery.discoverable?("nope")

      assert ModelDiscovery.refresh("codex", fetch: &never_fetch/1) ==
               {:error, {:model_discovery_unsupported, "codex"}}
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

  describe "the cache" do
    test "writes beside the other runtime state and reads back", %{cache: cache} do
      assert {:ok, _result} = refresh(openrouter_body([sonnet(), qwen()]), path: cache, now: ~U[2026-08-16 00:00:00Z])

      assert File.exists?(cache)
      assert ModelDiscovery.cached_models("openrouter", path: cache) == ["anthropic/claude-sonnet-5", "qwen/qwen4-max"]

      state = cache |> File.read!() |> Jason.decode!()
      assert state["version"] == 1
      assert state["backends"]["openrouter"]["fetched_at"] == "2026-08-16T00:00:00Z"
    end

    test "a corrupt or absent file degrades to the curated set, exactly as before discovery existed", %{cache: cache} do
      curated = CodingAgent.seedable_models("openrouter")

      assert ModelDiscovery.cached_models("openrouter", path: cache) == []
      assert ModelDiscovery.models_for("openrouter", path: cache, refresh: false) == curated

      File.write!(cache, "{not json at all")
      assert ModelDiscovery.cached_models("openrouter", path: cache) == []
      assert ModelDiscovery.models_for("openrouter", path: cache, refresh: false) == curated

      File.write!(cache, ~s({"version": 1}))
      assert ModelDiscovery.models_for("openrouter", path: cache, refresh: false) == curated
    end

    test "discovery only ever adds, and the curated list keeps its order and its meaning", %{cache: cache} do
      curated = CodingAgent.seedable_models("openrouter")
      assert "anthropic/claude-sonnet-5" in curated

      assert {:ok, _result} = refresh(openrouter_body([sonnet(), qwen()]), path: cache)

      models = ModelDiscovery.models_for("openrouter", path: cache, refresh: false)
      assert Enum.take(models, length(curated)) == curated
      assert models -- curated == ["qwen/qwen4-max"]
      assert models == Enum.uniq(models)

      # Curated metadata is untouched: discovery writes ids to a cache file and
      # nothing else. Efforts, aliases, and presentation stay registry-owned.
      assert CodingAgent.seedable_models("openrouter") == curated
    end

    test "staleness is the only refresh trigger, and it is a 24-hour TTL", %{cache: cache} do
      fetched_at = ~U[2026-08-16 00:00:00Z]
      assert {:ok, _result} = refresh(openrouter_body([sonnet()]), path: cache, now: fetched_at)

      refute ModelDiscovery.stale?("openrouter", path: cache, now: DateTime.add(fetched_at, 86_399, :second))
      assert ModelDiscovery.stale?("openrouter", path: cache, now: DateTime.add(fetched_at, 86_400, :second))
      assert ModelDiscovery.stale?("openrouter", path: Path.join(Path.dirname(cache), "absent.json"))

      assert ModelDiscovery.refresh_stale("openrouter",
               path: cache,
               now: fetched_at,
               fetch: &never_fetch/1
             ) == {:ok, :fresh}
    end

    test "an unreachable provider leaves the previous answer in place", %{cache: cache} do
      assert {:ok, _result} = refresh(openrouter_body([sonnet()]), path: cache)

      assert ModelDiscovery.refresh("openrouter", path: cache, fetch: fn _request -> {:error, :nxdomain} end) ==
               {:error, {:model_catalog_request, :nxdomain}}

      assert ModelDiscovery.refresh("openrouter", path: cache, fetch: fn _request -> {:ok, %{status: 503, body: ""}} end) ==
               {:error, {:model_catalog_status, 503}}

      assert ModelDiscovery.cached_models("openrouter", path: cache) == ["anthropic/claude-sonnet-5"]
    end
  end

  describe "config validation" do
    test "accepts a model the registry has never heard of, with a cold cache and no fetch", %{cache: cache} do
      # The hard requirement: validation reads the cache and nothing else. An
      # absent cache means "cannot verify", and a value aiur cannot verify is
      # accepted — aiur's list is expected to lag the provider.
      refute File.exists?(cache)

      assert {:ok, settings} =
               Schema.parse(%{
                 "agent" => %{
                   "kind" => "codex",
                   "backend_configs" => %{"openrouter" => %{"model" => "qwen/qwen4-max"}}
                 }
               })

      assert settings.agent.backend_configs["openrouter"]["model"] == "qwen/qwen4-max"

      # `never_fetch/1` flunks the test if it is ever called; the only discovery
      # function reachable from validation is the cache read.
      assert ModelDiscovery.cached_models("openrouter", path: cache, fetch: &never_fetch/1) == []
      assert ModelDiscovery.stale?("openrouter", path: cache)
    end

    test "the lazy refresh is off under :test, so no test can reach a provider", %{cache: cache} do
      assert Application.get_env(:aiur, :model_discovery_refresh?) == false

      assert ModelDiscovery.models_for("openrouter", path: cache, fetch: &never_fetch/1) ==
               CodingAgent.seedable_models("openrouter")
    end

    test "an operator can switch a backend's discovery off", %{cache: cache} do
      assert ModelDiscovery.models_for("openrouter", path: cache, enabled: false, fetch: &never_fetch/1) ==
               CodingAgent.seedable_models("openrouter")
    end
  end

  describe "discovered models are usable but visibly unpriced" do
    test "a discovered model with no curated row misses the price table by name", %{cache: cache} do
      assert {:ok, _result} = refresh(openrouter_body([sonnet(), qwen()]), path: cache)
      assert ModelDiscovery.unpriced_models("openrouter", path: cache) == ["qwen/qwen4-max"]

      assert {:ok, catalog} = PriceTable.default()

      assert {:error, :unknown_price_model} =
               PriceTable.lookup(catalog, price_query("qwen/qwen4-max"))

      assert {:ok, _entry} = PriceTable.lookup(catalog, price_query("anthropic/claude-sonnet-5"))
    end

    test "usage on an unpriced model reports unknown cost, never zero" do
      envelope = PricingFixture.codex_envelope!(%{resolved_model: "qwen/qwen4-max"})

      assert {:ok, result} =
               Pricing.resolve(
                 envelope,
                 PricingFixture.registry!(),
                 PricingFixture.default_price_table!(),
                 currency: "USD",
                 context_tier: :short_context
               )

      assert result.api_equivalent_estimate == nil
      assert result.api_equivalent_coverage == :unknown
      assert :unknown_price_model in result.coverage_reasons
    end
  end

  describe "fetched pricing is advisory" do
    test "a curated row that disagrees with the provider raises a drift finding", %{cache: cache} do
      # OpenRouter's curated DeepSeek row is 0.06426 / 0.12852 per million.
      quoted = %{
        "id" => "deepseek/deepseek-v4-flash",
        "pricing" => %{"prompt" => "0.0000002", "completion" => "0.0000004"}
      }

      assert {:ok, _result} = refresh(openrouter_body([quoted]), path: cache)

      drift = Map.new(ModelDiscovery.price_drift("openrouter", path: cache, on: ~D[2026-08-16]), &{&1.token_dimension, &1})

      assert Decimal.equal?(drift["input"].curated, Decimal.new("0.06426"))
      assert Decimal.equal?(drift["input"].discovered, Decimal.new("0.2"))
      assert drift["input"].provider == :openrouter
      assert Decimal.compare(drift["input"].relative_drift, Decimal.new("0.05")) == :gt
    end

    test "an agreeing quote is silent, and nothing is ever written into the price table", %{cache: cache} do
      agreeing = %{
        "id" => "deepseek/deepseek-v4-flash",
        "pricing" => %{"prompt" => "0.00000006426", "completion" => "0.00000012852"}
      }

      assert {:ok, before_refresh} = PriceTable.default()
      assert {:ok, _result} = refresh(openrouter_body([agreeing]), path: cache)

      assert ModelDiscovery.price_drift("openrouter", path: cache, on: ~D[2026-08-16]) == []

      # The curated table is a compile-time constant; a fetch cannot move it.
      assert {:ok, after_refresh} = PriceTable.default()
      assert after_refresh == before_refresh
    end

    test "a curated row that says free and a quote that says otherwise is not silent", %{cache: cache} do
      quoted = %{"id" => "vendor/model", "pricing" => %{"prompt" => "0.000001"}}
      assert {:ok, _result} = refresh(openrouter_body([quoted]), path: cache)

      assert [drift] =
               ModelDiscovery.price_drift("openrouter",
                 path: cache,
                 on: ~D[2026-08-16],
                 price_table: free_price_table()
               )

      assert Decimal.equal?(drift.curated, Decimal.new(0))
      assert Decimal.equal?(drift.discovered, Decimal.new(1))
      assert Decimal.equal?(drift.relative_drift, Decimal.new(1))
    end

    test "a model the curated table does not price at all is unpriced, not drifting", %{cache: cache} do
      assert {:ok, _result} = refresh(openrouter_body([qwen_priced()]), path: cache)

      assert ModelDiscovery.price_drift("openrouter", path: cache, on: ~D[2026-08-16]) == []
      assert ModelDiscovery.unpriced_models("openrouter", path: cache) == ["qwen/qwen4-max"]
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

  defp qwen, do: %{"id" => "qwen/qwen4-max", "name" => "Qwen: Qwen4 Max", "context_length" => 262_144}

  defp qwen_priced do
    %{"id" => "qwen/qwen4-max", "pricing" => %{"prompt" => "0.0000012", "completion" => "0.000006"}}
  end

  defp batch_variant do
    %{"id" => "moonshotai/kimi-k2.7-code:batch", "name" => "Kimi K2.7 Code (batch)"}
  end

  defp unstable_pointer, do: %{"id" => "~moonshotai/kimi-latest", "name" => "Kimi (latest)"}

  defp free_price_table do
    entry = %{
      provider: :openrouter,
      resolved_model: "vendor/model",
      token_dimension: :input,
      relationship_revision: "openrouter-request-usage-2026-08",
      currency: "USD",
      context_tier: :not_applicable,
      cache_write_duration: :not_applicable,
      price: "0.00",
      token_unit: 1_000_000,
      effective_date: ~D[2026-08-01],
      price_revision: "test-free-1",
      source_url: "https://example.com/pricing",
      source_reviewed_at: ~D[2026-08-01],
      pricing_scope: "test"
    }

    assert {:ok, catalog} = PriceTable.new("test-free-table", [entry])
    catalog
  end

  defp price_query(model) do
    %{
      provider: :openrouter,
      resolved_model: model,
      token_dimension: :input,
      relationship_revision: "openrouter-request-usage-2026-08",
      currency: "USD",
      context_tier: :not_applicable,
      cache_write_duration: :not_applicable,
      pricing_effective_date: ~D[2026-08-16]
    }
  end
end
