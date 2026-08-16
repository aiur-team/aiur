defmodule Aiur.Config.Schema.AgentValidationTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema.AgentValidation
  alias Ecto.Changeset

  # Renders through the same flattening Schema.parse surfaces to the operator,
  # so assertions pin the user-visible message, not Ecto's internal
  # `{message, opts}` change-error shape.
  defp rendered_errors(changeset), do: Aiur.Config.Schema.Errors.format_errors(changeset)

  describe "normalize_issue_state/1" do
    test "lowercases the state name" do
      assert AgentValidation.normalize_issue_state("In Progress") == "in progress"
      assert AgentValidation.normalize_issue_state("TODO") == "todo"
    end
  end

  describe "normalize_routing_level/1" do
    test "passes through integers" do
      assert AgentValidation.normalize_routing_level(3) == 3
    end

    test "parses string integers" do
      assert AgentValidation.normalize_routing_level("3") == 3
      assert AgentValidation.normalize_routing_level("10") == 10
    end

    test "passes through non-parseable strings" do
      assert AgentValidation.normalize_routing_level("high") == "high"
    end

    test "passes through other types" do
      assert AgentValidation.normalize_routing_level(:atom) == :atom
    end
  end

  describe "normalize_state_limits/1" do
    test "returns empty map for nil" do
      assert AgentValidation.normalize_state_limits(nil) == %{}
    end

    test "lowercases state name keys" do
      result = AgentValidation.normalize_state_limits(%{"In Progress" => 2, todo: 1})
      assert result == %{"in progress" => 2, "todo" => 1}
    end
  end

  describe "validate_state_limits/2" do
    defp make_changeset(value) do
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: value}, [:limits])
    end

    test "accepts a valid state limits map" do
      cs = make_changeset(%{"todo" => 3}) |> AgentValidation.validate_state_limits(:limits)
      assert cs.valid?
    end

    test "rejects blank state names" do
      cs = make_changeset(%{"" => 1}) |> AgentValidation.validate_state_limits(:limits)
      refute cs.valid?
      assert {_, _} = hd(cs.errors)
    end

    test "rejects non-positive integer limits" do
      cs = make_changeset(%{"todo" => 0}) |> AgentValidation.validate_state_limits(:limits)
      refute cs.valid?
    end
  end

  describe "normalize_agent_routing/1" do
    test "returns empty map for nil" do
      assert AgentValidation.normalize_agent_routing(nil) == %{}
    end

    test "parses string complexity levels to integers" do
      result = AgentValidation.normalize_agent_routing(%{"4" => "claude", 5 => :codex})
      assert result == %{4 => "claude", 5 => "codex"}
    end
  end

  describe "normalize_complexity_prompts/1" do
    test "returns empty map for nil" do
      assert AgentValidation.normalize_complexity_prompts(nil) == %{}
    end

    test "parses string complexity levels to integers" do
      result =
        AgentValidation.normalize_complexity_prompts(%{"3" => "medium guidance", 5 => "be careful"})

      assert result == %{3 => "medium guidance", 5 => "be careful"}
    end
  end

  describe "validate_agent_routing/2" do
    defp make_routing_changeset(value) do
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: value}, [:routing])
    end

    test "accepts a valid routing map" do
      cs = make_routing_changeset(%{3 => "claude"}) |> AgentValidation.validate_agent_routing(:routing)
      assert cs.valid?
    end

    test "accepts routing with model segment" do
      cs = make_routing_changeset(%{2 => "codex:gpt-5.5"}) |> AgentValidation.validate_agent_routing(:routing)
      assert cs.valid?
    end

    test "accepts +remote routing on a remote-capable backend" do
      cs = make_routing_changeset(%{5 => "claude+remote"}) |> AgentValidation.validate_agent_routing(:routing)
      assert cs.valid?
    end

    test "accepts routing with valid effort segment" do
      cs = make_routing_changeset(%{3 => "codex::high"}) |> AgentValidation.validate_agent_routing(:routing)
      assert cs.valid?
    end

    test "rejects non-positive complexity levels" do
      cs = make_routing_changeset(%{0 => "claude"}) |> AgentValidation.validate_agent_routing(:routing)
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :routing)
    end

    test "rejects unknown backend" do
      cs = make_routing_changeset(%{3 => "unknown-llm"}) |> AgentValidation.validate_agent_routing(:routing)
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :routing)
    end

    test "rejects +remote on non-remote-capable backend (codex)" do
      cs = make_routing_changeset(%{3 => "codex+remote"}) |> AgentValidation.validate_agent_routing(:routing)
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :routing)
    end

    test "rejects invalid effort for backend" do
      cs = make_routing_changeset(%{3 => "claude-repl::invalid-effort"}) |> AgentValidation.validate_agent_routing(:routing)
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :routing)
    end
  end

  describe "validate_complexity_prompts/2" do
    defp make_prompts_changeset(value) do
      {%{}, %{complexity_prompts: :map}}
      |> Changeset.cast(%{complexity_prompts: value}, [:complexity_prompts])
    end

    test "accepts valid complexity prompt map" do
      cs =
        make_prompts_changeset(%{3 => "be thorough"})
        |> AgentValidation.validate_complexity_prompts(:complexity_prompts)

      assert cs.valid?
    end

    test "rejects non-positive complexity levels" do
      cs =
        make_prompts_changeset(%{0 => "bad"})
        |> AgentValidation.validate_complexity_prompts(:complexity_prompts)

      refute cs.valid?
    end

    test "rejects non-string prompt values" do
      cs =
        make_prompts_changeset(%{3 => 123})
        |> AgentValidation.validate_complexity_prompts(:complexity_prompts)

      refute cs.valid?
    end
  end

  describe "validate_openrouter_backend_config/1" do
    defp make_backend_config_changeset(value) do
      {%{}, %{backend_configs: :map}}
      |> Changeset.cast(%{backend_configs: value}, [:backend_configs])
      |> AgentValidation.validate_openrouter_backend_config()
    end

    # Renders through the same flattening Schema.parse surfaces to the operator,
    # so these assertions pin the user-visible message, not Ecto's internal
    # `{message, opts}` change-error shape.
    test "accepts a valid nested openrouter tier" do
      cs =
        make_backend_config_changeset(%{
          "openrouter" => %{
            "enabled" => true,
            "model" => "router/auto",
            "provider" => %{
              "order" => ["DeepSeek", "Together AI"],
              "allow_fallbacks" => true,
              "ignore" => ["Azure"],
              "sort" => "price"
            }
          }
        })

      assert cs.valid?
    end

    test "accepts a leaf openrouter section (no provider tier)" do
      cs = make_backend_config_changeset(%{"openrouter" => %{"enabled" => true}})
      assert cs.valid?
    end

    test "accepts an absent openrouter section" do
      cs = make_backend_config_changeset(%{"fake" => %{"enabled" => true}})
      assert cs.valid?
    end

    test "rejects a non-map openrouter section" do
      cs = make_backend_config_changeset(%{"openrouter" => "not-a-map"})
      refute cs.valid?
      assert rendered_errors(cs) =~ "openrouter must be a map"
    end

    test "rejects a non-string openrouter.model" do
      cs = make_backend_config_changeset(%{"openrouter" => %{"model" => 7}})
      refute cs.valid?
      assert rendered_errors(cs) =~ "openrouter.model must be a non-empty string"
    end

    test "rejects an unsupported provider parameter" do
      cs =
        make_backend_config_changeset(%{
          "openrouter" => %{"provider" => %{"provider_override" => "secret"}}
        })

      refute cs.valid?
      assert rendered_errors(cs) =~ "not a supported OpenRouter provider parameter"
    end

    test "rejects a non-map provider value" do
      cs = make_backend_config_changeset(%{"openrouter" => %{"provider" => "price"}})
      refute cs.valid?
      assert rendered_errors(cs) =~ "openrouter.provider must be a map"
    end

    test "rejects an invalid provider.order element" do
      cs =
        make_backend_config_changeset(%{
          "openrouter" => %{"provider" => %{"order" => ["DeepSeek", ""]}}
        })

      refute cs.valid?
      assert rendered_errors(cs) =~ "provider.order must be a list of non-empty strings"
    end

    test "rejects a non-boolean allow_fallbacks" do
      cs =
        make_backend_config_changeset(%{
          "openrouter" => %{"provider" => %{"allow_fallbacks" => "yes"}}
        })

      refute cs.valid?
      assert rendered_errors(cs) =~ "provider.allow_fallbacks must be a boolean"
    end

    test "rejects an invalid provider.sort" do
      cs =
        make_backend_config_changeset(%{
          "openrouter" => %{"provider" => %{"sort" => "cheapest"}}
        })

      refute cs.valid?
      assert rendered_errors(cs) =~ "provider.sort must be one of"
    end

    test "rejects an invalid provider.route" do
      cs =
        make_backend_config_changeset(%{
          "openrouter" => %{"provider" => %{"route" => "sometimes"}}
        })

      refute cs.valid?
      assert rendered_errors(cs) =~ "provider.route must be one of"
    end

    test "rejects a non-positive provider.max_retries" do
      cs =
        make_backend_config_changeset(%{
          "openrouter" => %{"provider" => %{"max_retries" => 0}}
        })

      refute cs.valid?
      assert rendered_errors(cs) =~ "provider.max_retries must be a positive integer"
    end

    test "rejects router/auto without a provider policy" do
      cs = make_backend_config_changeset(%{"openrouter" => %{"model" => "router/auto"}})
      refute cs.valid?
      assert rendered_errors(cs) =~ "router/auto needs a provider policy"
    end

    test "accepts router/auto with a provider.order" do
      cs =
        make_backend_config_changeset(%{
          "openrouter" => %{"model" => "router/auto", "provider" => %{"order" => ["DeepSeek"]}}
        })

      assert cs.valid?
    end

    test "accepts router/auto with a non-none provider.sort" do
      cs =
        make_backend_config_changeset(%{
          "openrouter" => %{"model" => "router/auto", "provider" => %{"sort" => "throughput"}}
        })

      assert cs.valid?
    end
  end

  describe "validate_agent_routing/2 with delegated openrouter router/auto" do
    defp make_routing_config_changeset(routing, backend_configs) do
      {%{}, %{routing: :map, backend_configs: :map, priority: {:array, :string}}}
      |> Changeset.cast(%{routing: routing, backend_configs: backend_configs}, [:routing, :backend_configs, :priority])
      |> AgentValidation.validate_agent_routing(:routing)
    end

    test "accepts openrouter:router/auto when the tier pins a provider policy" do
      cs =
        make_routing_config_changeset(%{3 => "openrouter:router/auto"}, %{
          "openrouter" => %{"provider" => %{"sort" => "price"}}
        })

      assert cs.valid?
    end

    test "rejects openrouter:router/auto without a provider policy" do
      cs = make_routing_config_changeset(%{3 => "openrouter:router/auto"}, %{})
      refute cs.valid?
      assert rendered_errors(cs) =~ "router/auto needs a provider policy"
    end

    test "accepts a concrete openrouter model path without a provider policy" do
      cs =
        make_routing_config_changeset(%{3 => "openrouter:deepseek/deepseek-v4-flash"}, %{})

      assert cs.valid?
    end
  end
end
