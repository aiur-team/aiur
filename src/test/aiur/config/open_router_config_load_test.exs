defmodule Aiur.Config.OpenRouterConfigLoadTest do
  # Config-load wiring for the OpenRouter routing block: the backend registry's
  # validator is what turns a misspelled provider field into a config error.
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema

  test "OpenRouter routing fields load and unknown ones are rejected" do
    openrouter = fn provider ->
      Schema.parse(%{
        "agent" => %{
          "priority" => ["openrouter:anthropic/claude-sonnet-5"],
          "backend_configs" => %{"openrouter" => %{"provider" => provider}}
        }
      })
    end

    assert {:ok, settings} =
             openrouter.(%{
               "order" => ["Anthropic"],
               "only" => ["Anthropic"],
               "ignore" => ["Azure"],
               "allow_fallbacks" => false,
               "sort" => "price",
               "max_price" => %{"prompt" => 0.5, "completion" => 1.0},
               "quantizations" => ["fp8"],
               "data_collection" => "deny",
               "require_parameters" => true
             })

    assert settings.agent.backend_configs["openrouter"]["provider"]["sort"] == "price"

    assert {:error, {:invalid_workflow_config, message}} = openrouter.(%{"max_tokens" => 100})
    assert message =~ "openrouter"
    assert message =~ "max_tokens"
  end

  test "OpenRouter named model sets load and unknown route keys are rejected" do
    openrouter = fn routes ->
      Schema.parse(%{
        "agent" => %{
          "priority" => ["openrouter:cheap"],
          "backend_configs" => %{"openrouter" => %{"routes" => routes}}
        }
      })
    end

    assert {:ok, settings} =
             openrouter.(%{"cheap" => %{"models" => ["deepseek/deepseek-v4-flash"], "provider" => %{"sort" => "price"}}})

    assert settings.agent.backend_configs["openrouter"]["routes"]["cheap"]["models"] == ["deepseek/deepseek-v4-flash"]

    assert {:error, {:invalid_workflow_config, message}} = openrouter.(%{"cheap" => %{"model" => "deepseek/deepseek-v4-flash"}})
    assert message =~ "routes.cheap has an unknown field"
  end

  test "command_sandbox is validated at config load, not only in the validator module" do
    load = fn sandbox ->
      Schema.parse(%{
        "agent" => %{
          "priority" => ["openrouter:cheap"],
          "backend_configs" => %{"openrouter" => %{"command_sandbox" => sandbox}}
        }
      })
    end

    assert {:ok, settings} = load.(%{"read_only_binds" => ["/opt/node"]})
    assert settings.agent.backend_configs["openrouter"]["command_sandbox"]["read_only_binds"] == ["/opt/node"]

    for {sandbox, fragment} <- [
          {%{"read_only_binds" => ["relative/dir"]}, "must be absolute"},
          {%{"writable_binds" => ["/"]}, "must not be /"},
          {%{"path" => [Path.join(System.user_home!(), ".aiur/instances")]}, "~/.aiur"}
        ] do
      assert {:error, {:invalid_workflow_config, message}} = load.(sandbox)
      assert message =~ "openrouter"
      assert message =~ fragment
    end
  end
end
