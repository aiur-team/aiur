defmodule Aiur.Config.HostedAuthPolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.{AgentSettings, HostedAuthPolicy, Schema}
  alias Aiur.Orchestrator.HostedModeCheck

  @safe_hosted %{
    permission_boundary: :enforced,
    network_boundary: :denied,
    credential_boundary: :daemon
  }

  @api_key_entry %{
    accounts: %{kind: :api_key},
    account_generation: %{auth_modes: ["api_key"]},
    rate_limit_fallback_target: true,
    hosted_execution: @safe_hosted
  }

  test "local mode preserves every runtime authentication class" do
    for auth_class <- [:api_key, :subscription, :oauth, :personal_token, :headers, :agent_identity, :bedrock, :unknown] do
      assert :ok = HostedAuthPolicy.authorize("local", "codex", auth_class)
    end
  end

  test "hosted mode accepts only a normalized API-key observation" do
    assert :ok = HostedAuthPolicy.authorize("hosted", "codex", :api_key)

    for auth_class <- [:subscription, :oauth, :personal_token, :headers, :agent_identity, :bedrock, :unknown] do
      assert HostedAuthPolicy.authorize("hosted", "codex", auth_class) ==
               {:error, {:unsafe_hosted_authentication, "codex", auth_class}}
    end
  end

  test "fallback contracts must be complete and API-key-only" do
    assert HostedAuthPolicy.api_key_only_fallback?(@api_key_entry)
    assert HostedAuthPolicy.api_key_only_fallback?(put_in(@api_key_entry, [:account_generation, :auth_modes], ["apikey"]))

    refute HostedAuthPolicy.api_key_only_fallback?(put_in(@api_key_entry, [:accounts, :kind], :profile))
    refute HostedAuthPolicy.api_key_only_fallback?(put_in(@api_key_entry, [:account_generation, :auth_modes], ["api_key", "subscription"]))
    refute HostedAuthPolicy.api_key_only_fallback?(put_in(@api_key_entry, [:account_generation, :auth_modes], []))
    refute HostedAuthPolicy.api_key_only_fallback?(Map.delete(@api_key_entry, :accounts))
    refute HostedAuthPolicy.api_key_only_fallback?(%{})
  end

  test "effective fallback resolution follows priority before the legacy setting" do
    priority =
      settings("local", %{
        "agent" => %{
          "priority" => ["codex", "claude", "openrouter:anthropic/claude-sonnet-5"],
          "rate_limit_fallback" => "openrouter"
        }
      })

    assert AgentSettings.rate_limit_fallback_backend(priority, ["claude", "openrouter"]) == "claude"

    legacy = settings("local", %{"agent" => %{"rate_limit_fallback" => "openrouter"}})
    assert AgentSettings.rate_limit_fallback_backend(legacy, ["claude", "openrouter"]) == "openrouter"

    disabled = settings("local", %{"agent" => %{"rate_limit_fallback" => ""}})
    assert AgentSettings.rate_limit_fallback_backend(disabled, ["claude", "openrouter"]) == nil
  end

  test "hosted semantic validation rejects the default profile fallback" do
    entries = %{
      "safe" => %{hosted_execution: @safe_hosted},
      "claude" => %{
        accounts: %{kind: :profile},
        account_generation: %{auth_modes: ["subscription", "api_key"]},
        rate_limit_fallback_target: true
      }
    }

    assert {:error, {:unsafe_hosted_mode, violations}} =
             HostedModeCheck.validate(settings("hosted"),
               booted_mode: nil,
               interactive_cli?: false,
               registry_entries: entries,
               dispatchable_backends: ["safe"],
               contributor_boundaries: []
             )

    assert "agent usage-limit fallback \"claude\" is not statically API-key-only" in violations
  end

  test "hosted semantic validation accepts disabled and API-key-only fallbacks" do
    safe_entry = %{hosted_execution: @safe_hosted}
    entries = %{"codex" => safe_entry, "openrouter" => @api_key_entry}

    disabled = settings("hosted", %{"agent" => %{"rate_limit_fallback" => ""}})

    assert :ok =
             HostedModeCheck.validate(disabled,
               booted_mode: nil,
               interactive_cli?: false,
               registry_entries: entries,
               dispatchable_backends: ["codex"],
               contributor_boundaries: []
             )

    priority =
      settings("hosted", %{
        "agent" => %{"priority" => ["codex", "openrouter:anthropic/claude-sonnet-5"]}
      })

    assert :ok =
             HostedModeCheck.validate(priority,
               booted_mode: nil,
               interactive_cli?: false,
               registry_entries: entries,
               dispatchable_backends: ["codex", "openrouter"],
               contributor_boundaries: []
             )
  end

  defp settings(mode, extra \\ %{}) do
    assert {:ok, settings} = Schema.parse(Map.merge(%{"instance" => %{"mode" => mode}}, extra))
    settings
  end
end
