defmodule Aiur.Orchestrator.HostedModeCheckTest do
  use ExUnit.Case, async: true

  alias Aiur.Application.StartupChecks
  alias Aiur.Config.Schema
  alias Aiur.Issue
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.HostedModeCheck
  alias Aiur.Orchestrator.State

  defmodule SafeContributor do
  end

  defmodule UnknownContributor do
  end

  @safe_entry %{
    delivery: %{transport: :app_server},
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
    untouched = fn -> flunk("local mode must not inspect hosted-only inputs") end

    assert :ok =
             HostedModeCheck.validate(settings("local"),
               booted_mode: "local",
               interactive_cli?: untouched,
               registry_entries: untouched,
               dispatchable_backends: untouched,
               contributor_boundaries: untouched
             )

    assert :ok =
             HostedModeCheck.validate_dispatch(settings("local"), %Issue{labels: ["model:remote"]}, remote_override?: untouched)
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
               booted_mode: nil,
               registry_entries: %{"safe" => @safe_entry},
               dispatchable_backends: ["safe"],
               contributor_boundaries: []
             )
  end

  test "hosted mode has a passing path through the real test registry" do
    assert :ok =
             HostedModeCheck.validate(settings("hosted"),
               booted_mode: nil,
               dispatchable_backends: ["fake"],
               contributor_boundaries: []
             )
  end

  test "every production backend in the real registry currently fails closed" do
    production_entries = Map.delete(Aiur.CodingAgent.backends(), "fake")
    assert map_size(production_entries) > 0

    for backend <- Map.keys(production_entries) do
      assert {:error, {:unsafe_hosted_mode, violations}} =
               HostedModeCheck.validate(settings("hosted"),
                 booted_mode: nil,
                 dispatchable_backends: [backend],
                 contributor_boundaries: []
               )

      assert violations != [], "#{backend} unexpectedly passed hosted isolation"
    end
  end

  test "hosted mode refuses agent.remote_control" do
    global_remote = settings("hosted", %{"agent" => %{"remote_control" => true}})

    assert {:error, {:unsafe_hosted_mode, global_violations}} = validate_safe(global_remote)
    assert "agent.remote_control is not allowed" in global_violations
  end

  test "hosted mode refuses +remote routing" do
    routed_remote =
      settings("hosted", %{
        "agent" => %{"routing" => %{"3" => "claude:sonnet+remote"}}
      })

    assert {:error, {:unsafe_hosted_mode, routing_violations}} = validate_safe(routed_remote)
    assert "agent.routing route \"claude:sonnet+remote\" enables +remote" in routing_violations
  end

  test "hosted mode refuses local tmux panes" do
    assert {:error, {:unsafe_hosted_mode, pane_violations}} =
             validate_safe(settings("hosted"), interactive_cli?: true)

    assert "local tmux panes are not allowed" in pane_violations
  end

  test "hosted mode refuses local REPL transports" do
    repl_entry = put_in(@safe_entry, [:delivery, :transport], :tmux_pane)

    assert {:error, {:unsafe_hosted_mode, violations}} =
             validate_safe(settings("hosted"),
               registry_entries: %{"claude-repl" => repl_entry},
               dispatchable_backends: ["claude-repl"]
             )

    assert "backend claude-repl uses a local tmux REPL transport" in violations
  end

  test "hosted dispatch refuses model:remote overrides" do
    issue = %Issue{id: "hosted-remote", identifier: "hosted-remote", labels: ["model:remote"]}

    assert HostedModeCheck.validate_dispatch(settings("hosted"), issue, safe_opts()) ==
             {:error, {:unsafe_hosted_mode, ["model:remote overrides are not allowed"]}}

    state =
      Dispatcher.do_dispatch_issue(
        %State{},
        issue,
        nil,
        nil,
        safe_opts() ++
          [
            hosted_mode_settings: settings("hosted"),
            runner: fn _, _, _ -> flunk("hosted model:remote dispatch must not start") end
          ]
      )

    assert state.dispatch_declines[issue.id] ==
             {:unsafe_hosted_mode, ["model:remote overrides are not allowed"]}
  end

  test "hosted dispatch refuses model:claude-repl overrides" do
    issue = %Issue{id: "hosted-repl", identifier: "hosted-repl", labels: ["model:claude-repl"]}
    repl_entry = put_in(@safe_entry, [:delivery, :transport], :tmux_pane)

    opts =
      safe_opts()
      |> Keyword.put(:registry_entries, %{"safe" => @safe_entry, "claude-repl" => repl_entry})
      |> Keyword.put(:dispatch_backend, "claude-repl")

    assert HostedModeCheck.validate_dispatch(settings("hosted"), issue, opts) ==
             {:error, {:unsafe_hosted_mode, ["backend claude-repl uses a local tmux REPL transport"]}}

    state =
      Dispatcher.do_dispatch_issue(
        %State{},
        issue,
        nil,
        nil,
        opts ++
          [
            hosted_mode_settings: settings("hosted"),
            runner: fn _, _, _ -> flunk("hosted model:claude-repl dispatch must not start") end
          ]
      )

    assert state.dispatch_declines[issue.id] ==
             {:unsafe_hosted_mode, ["backend claude-repl uses a local tmux REPL transport"]}
  end

  test "hosted mode checks Codex approval policy directly" do
    never = settings("hosted", %{"agent" => %{"codex" => %{"approval_policy" => "never"}}})
    assert {:error, {:unsafe_hosted_mode, approval_violations}} = validate_safe(never)
    assert "agent.codex.approval_policy must require approval, got \"never\"" in approval_violations
  end

  test "hosted mode checks Codex thread sandbox directly" do
    unbounded =
      settings("hosted", %{
        "agent" => %{"codex" => %{"thread_sandbox" => "danger-full-access"}}
      })

    assert {:error, {:unsafe_hosted_mode, sandbox_violations}} = validate_safe(unbounded)
    assert "agent.codex.thread_sandbox must be bounded, got \"danger-full-access\"" in sandbox_violations
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
      StartupChecks.validate_hosted_mode!({:ok, settings("hosted")}, booted_mode: nil)
    end
  end

  defp validate_safe(settings, overrides \\ []) do
    HostedModeCheck.validate(settings, Keyword.merge(safe_opts(), overrides))
  end

  defp safe_opts do
    [
      booted_mode: nil,
      registry_entries: %{"safe" => @safe_entry},
      dispatchable_backends: ["safe"],
      contributor_boundaries: [],
      interactive_cli?: false
    ]
  end

  defp settings(mode, extra \\ %{}) do
    config = Map.merge(%{"instance" => %{"mode" => mode}}, extra)

    config =
      if mode == "hosted" do
        Map.update(config, "agent", %{"rate_limit_fallback" => ""}, &Map.put_new(&1, "rate_limit_fallback", ""))
      else
        config
      end

    assert {:ok, settings} = Schema.parse(config)
    settings
  end
end
