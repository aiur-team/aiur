defmodule Aiur.Orchestrator.HostedModeCheckTest do
  use ExUnit.Case, async: true

  alias Aiur.Application.StartupChecks
  alias Aiur.Config.Schema
  alias Aiur.Orchestrator.HostedModeCheck

  defmodule SafeContributor do
  end

  defmodule UnknownContributor do
  end

  @safe_entry %{
    hosted_execution: %{
      permission_boundary: :enforced,
      network_boundary: :denied,
      credential_boundary: :daemon
    }
  }

  @safe_codex_entry %{
    hosted_execution: %{
      permission_boundary: :codex_sandbox,
      network_boundary: :codex_sandbox,
      credential_boundary: :daemon
    }
  }

  @safe_claude_entry %{
    hosted_execution: %{
      permission_boundary: :claude_permission_mode,
      network_boundary: :denied,
      credential_boundary: :daemon
    }
  }

  test "local mode preserves existing behavior without inspecting hosted capabilities" do
    assert :ok = HostedModeCheck.validate(settings("local"), booted_mode: "local", dispatchable_backends: ["missing"])
  end

  test "hosted mode accepts only explicitly safe backend and contributor boundaries" do
    hosted = settings("hosted")

    assert :ok =
             HostedModeCheck.validate(hosted,
               booted_mode: nil,
               registry_entries: %{"safe" => @safe_entry},
               dispatchable_backends: ["safe"],
               contributor_boundaries: [{SafeContributor, :daemon}]
             )

    assert :ok =
             StartupChecks.validate_hosted_mode({:ok, hosted},
               registry_entries: %{"safe" => @safe_entry},
               dispatchable_backends: ["safe"],
               contributor_boundaries: []
             )
  end

  test "agent priority backends are included even when their registry default is disabled" do
    hosted = settings("hosted", %{"agent" => %{"priority" => ["deepseek"]}})

    assert {:error, {:unsafe_hosted_mode, violations}} =
             HostedModeCheck.validate(hosted,
               booted_mode: nil,
               contributor_boundaries: []
             )

    assert Enum.any?(violations, &String.starts_with?(&1, "backend deepseek "))
  end

  test "hosted mode aggregates unsafe Codex defaults and agent-reachable credentials" do
    hosted = settings("hosted")

    assert {:error, {:unsafe_hosted_mode, violations}} =
             HostedModeCheck.validate(hosted,
               booted_mode: nil,
               registry_entries: %{"codex" => Aiur.CodingAgent.backends()["codex"]},
               dispatchable_backends: ["codex"],
               contributor_boundaries: [{UnknownContributor, :unknown}]
             )

    assert violations == [
             "backend codex requires agent.codex.turn_sandbox_policy.networkAccess=false, got true",
             "backend codex does not keep credentials daemon-side (:agent)",
             "agent environment contributor Aiur.Orchestrator.HostedModeCheckTest.UnknownContributor does not keep credentials daemon-side (:unknown)"
           ]
  end

  test "Codex and Claude configuration-specific boundaries fail closed" do
    hosted = settings("hosted")
    entries = Aiur.CodingAgent.backends()

    assert {:error, {:unsafe_hosted_mode, codex_violations}} =
             HostedModeCheck.validate(hosted,
               booted_mode: nil,
               registry_entries: entries,
               dispatchable_backends: ["codex"],
               contributor_boundaries: []
             )

    assert Enum.any?(codex_violations, &String.contains?(&1, "networkAccess=false"))

    assert {:error, {:unsafe_hosted_mode, claude_violations}} =
             HostedModeCheck.validate(hosted,
               booted_mode: nil,
               registry_entries: entries,
               dispatchable_backends: ["claude"],
               contributor_boundaries: []
             )

    assert "backend claude uses agent.claude.permission_mode=bypassPermissions" in claude_violations
    assert Enum.any?(claude_violations, &String.contains?(&1, "does not deny agent network access"))
  end

  test "Codex requires a bounded sandbox with explicit network denial" do
    for type <- ["workspaceWrite", "readOnly"] do
      hosted =
        settings("hosted", %{
          "agent" => %{
            "codex" => %{
              "turn_sandbox_policy" => %{"type" => type, "networkAccess" => false}
            }
          }
        })

      assert :ok =
               HostedModeCheck.validate(hosted,
                 booted_mode: nil,
                 registry_entries: %{"codex" => @safe_codex_entry},
                 dispatchable_backends: ["codex"],
                 contributor_boundaries: []
               )
    end

    hosted =
      settings("hosted", %{
        "agent" => %{
          "codex" => %{
            "turn_sandbox_policy" => %{
              "type" => "dangerFullAccess",
              "networkAccess" => false
            }
          }
        }
      })

    assert HostedModeCheck.validate(hosted,
             booted_mode: nil,
             registry_entries: %{"codex" => @safe_codex_entry},
             dispatchable_backends: ["codex"],
             contributor_boundaries: []
           ) ==
             {:error, {:unsafe_hosted_mode, ["backend codex has unsafe Codex sandbox type \"dangerFullAccess\""]}}
  end

  test "Claude accepts only non-bypass permission modes" do
    for mode <- ["default", "acceptEdits"] do
      hosted =
        settings("hosted", %{
          "agent" => %{"claude" => %{"permission_mode" => mode}}
        })

      assert :ok =
               HostedModeCheck.validate(hosted,
                 booted_mode: nil,
                 registry_entries: %{"claude" => @safe_claude_entry},
                 dispatchable_backends: ["claude"],
                 contributor_boundaries: []
               )
    end
  end

  test "missing backend declarations and disabled backends fail closed" do
    assert HostedModeCheck.validate(settings("hosted"),
             booted_mode: nil,
             registry_entries: %{},
             dispatchable_backends: ["missing"],
             contributor_boundaries: []
           ) ==
             {:error,
              {:unsafe_hosted_mode,
               [
                 "backend missing has no trusted permission boundary (:unknown)",
                 "backend missing does not deny agent network access (:unknown)",
                 "backend missing does not keep credentials daemon-side (:unknown)"
               ]}}

    hosted =
      settings("hosted", %{
        "agent" => %{
          "kind" => "claude",
          "priority" => ["claude"],
          "rate_limit_primary" => "claude",
          "rate_limit_fallback" => "",
          "backend_configs" => %{"codex" => %{"enabled" => false}}
        }
      })

    assert {:error, {:unsafe_hosted_mode, violations}} =
             HostedModeCheck.validate(hosted,
               booted_mode: nil,
               contributor_boundaries: []
             )

    refute Enum.any?(violations, &String.starts_with?(&1, "backend codex "))
  end

  test "instance mode changes require a restart before hosted checks run" do
    assert HostedModeCheck.validate(settings("hosted"), booted_mode: "local") ==
             {:error, {:instance_mode_change_requires_restart, "local", "hosted"}}

    assert HostedModeCheck.validate(settings("local"), booted_mode: "hosted") ==
             {:error, {:instance_mode_change_requires_restart, "hosted", "local"}}
  end

  test "formatted errors name every rejected boundary without secret values" do
    message =
      Aiur.Config.format_config_error(
        {:unsafe_hosted_mode,
         [
           "backend codex does not deny agent network access (:unrestricted)",
           "agent environment contributor Example does not keep credentials daemon-side (:agent)"
         ]}
      )

    assert message ==
             "Hosted mode safety checks failed:\n- backend codex does not deny agent network access (:unrestricted)\n- agent environment contributor Example does not keep credentials daemon-side (:agent)"
  end

  test "startup bang check refuses unsafe hosted configuration with the formatted reason" do
    assert_raise ArgumentError, ~r/Hosted mode safety checks failed:/, fn ->
      StartupChecks.validate_hosted_mode!({:ok, settings("hosted")})
    end
  end

  defp settings(mode, extra \\ %{}) do
    config = Map.merge(%{"instance" => %{"mode" => mode}}, extra)
    assert {:ok, settings} = Schema.parse(config)
    settings
  end
end
