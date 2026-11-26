defmodule Aiur.CodingAgent.ConfigCatalogTest do
  use ExUnit.Case, async: true

  alias Aiur.CodingAgent
  alias Aiur.CodingAgent.ConfigCatalog
  alias Aiur.Config.Schema.Agent

  # Future registry changes must update the schema's compile-time literals too.
  test "schema compile-time defaults equal the registry's answers" do
    agent = %Agent{}
    assert agent.kind == ConfigCatalog.default_backend()
    assert agent.rate_limit_primary == ConfigCatalog.default_backend()
    assert agent.rate_limit_fallback == ConfigCatalog.default_rate_limit_fallback()
  end

  test "catalog preserves registry views, model grammar and issue complexity" do
    for name <- [:known_backends, :default_backend, :default_config_backend, :default_rate_limit_fallback, :rate_limit_fallback_targets, :configurable_backends] do
      assert apply(ConfigCatalog, name, []) == apply(CodingAgent, name, [])
    end

    for backend <- CodingAgent.known_backends() do
      assert ConfigCatalog.models(backend) == CodingAgent.models(backend)
      assert ConfigCatalog.efforts(backend) == CodingAgent.efforts(backend)
      assert ConfigCatalog.remote_control?(backend) == CodingAgent.remote_control?(backend)
      assert ConfigCatalog.model_required?(backend) == CodingAgent.model_required?(backend)
      assert ConfigCatalog.config_validator(backend) == get_in(CodingAgent.backends(), [backend, :config_validator])
    end

    configs = %{"openrouter" => %{"enabled" => true}}
    assert ConfigCatalog.dispatchable_backends(configs) == CodingAgent.dispatchable_backends(configs)
    assert ConfigCatalog.complexity_level(%Aiur.Issue{labels: []}) == nil
    assert ConfigCatalog.complexity_level(%Aiur.Issue{labels: ["complexity:3"]}) == 3
    refute ConfigCatalog.ambiguous_model_alias?("codex", nil)
  end
end
