defmodule Aiur.Config.SchemaSectionsTest do
  use ExUnit.Case, async: true

  alias Aiur.Config
  alias Aiur.Config.Schema

  describe "workspace.root resolution" do
    test "missing env var for $ROOT_VAR falls back to tmp default" do
      System.delete_env("AIUR_TEST_ROOT_MISSING")

      {:ok, settings} =
        Schema.parse(%{"workspace" => %{"root" => "$AIUR_TEST_ROOT_MISSING"}})

      assert settings.workspace.root == Path.join(System.tmp_dir!(), "aiur_workspaces")
    end

    test "empty workspace root falls back to tmp default" do
      # Empty string root (after normalize_keys, pre-cast drop) uses the default
      {:ok, settings} = Schema.parse(%{"workspace" => %{"root" => ""}})
      assert settings.workspace.root == Path.join(System.tmp_dir!(), "aiur_workspaces")
    end

    test "absent workspace section uses tmp default" do
      {:ok, settings} = Schema.parse(%{})
      assert settings.workspace.root == Path.join(System.tmp_dir!(), "aiur_workspaces")
    end
  end

  # FI-CFG-003: multi-level format_errors dotted flattening
  describe "format_errors dotted path flattening" do
    test "nested field errors are prefixed with dotted path" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"polling" => %{"interval_seconds" => -1}})

      assert message =~ "polling.interval_seconds"
    end

    test "doubly-nested field errors include full dotted path" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"agent" => %{"codex" => %{"read_timeout_ms" => -1}}})

      assert message =~ "agent.codex.read_timeout_ms"
    end

    test "multiple errors are comma-joined" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{
                 "polling" => %{"interval_seconds" => -1},
                 "max_vertical_panes" => -1
               })

      assert message =~ ","
    end
  end

  # Smoke casts for zero-coverage sections
  describe "zero-coverage section smoke casts" do
    test "Events section parses with defaults" do
      {:ok, settings} = Schema.parse(%{})
      assert settings.events.block_state_debounce_seconds == 10
      assert settings.events.custom_events_per_turn_max == 5
      assert settings.events.codeowners_refresh_seconds == 3_600
    end

    test "Events section accepts explicit values" do
      {:ok, settings} =
        Schema.parse(%{
          "events" => %{
            "block_state_debounce_seconds" => 20,
            "custom_events_per_turn_max" => 10,
            "codeowners_refresh_seconds" => 7_200
          }
        })

      assert settings.events.block_state_debounce_seconds == 20
      assert settings.events.custom_events_per_turn_max == 10
      assert settings.events.codeowners_refresh_seconds == 7_200
    end

    test "Decisions section defaults supervisor autonomy to denied" do
      {:ok, settings} = Schema.parse(%{})

      assert settings.decisions.supervisor_allowed_kinds == []
      assert settings.decisions.supervisor_allow_non_reversible == false
    end

    test "Decisions section normalizes an explicit supervisor policy" do
      {:ok, settings} =
        Schema.parse(%{
          "decisions" => %{
            "supervisor_allowed_kinds" => [" Architecture ", "product", "ARCHITECTURE"],
            "supervisor_allow_non_reversible" => true
          }
        })

      assert settings.decisions.supervisor_allowed_kinds == ["architecture", "product"]
      assert settings.decisions.supervisor_allow_non_reversible == true
    end

    test "Decisions section rejects unsafe or unbounded supervisor kinds" do
      invalid_kind_sets = [
        [""],
        ["   "],
        ["architecture\n"],
        ["architecture\u0000credential"],
        [String.duplicate("a", 101)],
        Enum.map(1..101, &"kind-#{&1}")
      ]

      for kinds <- invalid_kind_sets do
        assert {:error, {:invalid_workflow_config, message}} =
                 Schema.parse(%{"decisions" => %{"supervisor_allowed_kinds" => kinds}})

        assert message =~ "decisions.supervisor_allowed_kinds"
      end
    end

    test "Hooks section parses with defaults" do
      {:ok, settings} = Schema.parse(%{})
      assert settings.hooks.timeout_ms == 600_000
      assert settings.hooks.after_create == nil
    end

    test "Hooks section accepts explicit values" do
      {:ok, settings} =
        Schema.parse(%{
          "hooks" => %{"before_run" => "make setup", "timeout_ms" => 30_000}
        })

      assert settings.hooks.before_run == "make setup"
      assert settings.hooks.timeout_ms == 30_000
    end

    test "Worker section parses with defaults" do
      {:ok, settings} = Schema.parse(%{})
      assert settings.worker.ssh_hosts == []
      assert settings.worker.max_concurrent_agents_per_host == nil
    end

    test "Worker section accepts explicit values" do
      {:ok, settings} =
        Schema.parse(%{
          "worker" => %{"ssh_hosts" => ["host1", "host2"], "max_concurrent_agents_per_host" => 3}
        })

      assert settings.worker.ssh_hosts == ["host1", "host2"]
      assert settings.worker.max_concurrent_agents_per_host == 3
    end

    test "Observability section parses with defaults" do
      {:ok, settings} = Schema.parse(%{})
      assert settings.observability.dashboard_enabled == true
      assert settings.observability.build_order_funnel_health_check == false
      assert settings.observability.dashboard_writable == true
      assert settings.observability.refresh_ms == 1_000
      assert settings.observability.telemetry_enabled == true
      assert settings.observability.telemetry_retention_max_bytes == 64 * 1024 * 1024
      assert settings.observability.telemetry_retention_max_age_days == 30
      assert settings.observability.telemetry_retention_prune_interval_bytes == nil
    end

    test "Funnel health checking is disabled by default and enabled explicitly" do
      assert {:ok, defaults} = Schema.parse(%{})
      refute Config.build_order_funnel_health_check_enabled?({:ok, defaults})

      assert {:ok, enabled} =
               Schema.parse(%{"observability" => %{"build_order_funnel_health_check" => true}})

      assert Config.build_order_funnel_health_check_enabled?({:ok, enabled})
    end

    test "Observability section accepts explicit values" do
      {:ok, settings} =
        Schema.parse(%{
          "observability" => %{
            "dashboard_enabled" => false,
            "build_order_funnel_health_check" => true,
            "dashboard_writable" => true,
            "refresh_ms" => 500,
            "telemetry_enabled" => false,
            "telemetry_retention_max_bytes" => 1_024,
            "telemetry_retention_max_age_days" => 7,
            "telemetry_retention_prune_interval_bytes" => 128
          }
        })

      assert settings.observability.dashboard_enabled == false
      assert settings.observability.build_order_funnel_health_check == true
      assert settings.observability.dashboard_writable == true
      assert settings.observability.refresh_ms == 500
      assert settings.observability.telemetry_enabled == false
      assert settings.observability.telemetry_retention_max_bytes == 1_024
      assert settings.observability.telemetry_retention_max_age_days == 7
      assert settings.observability.telemetry_retention_prune_interval_bytes == 128
    end

    test "Monitoring section parses with defaults" do
      {:ok, settings} = Schema.parse(%{})
      assert settings.monitoring.daemon_heartbeat_stale_ms == 3_600_000
    end

    test "Monitoring section accepts explicit values" do
      {:ok, settings} =
        Schema.parse(%{
          "monitoring" => %{
            "daemon_heartbeat_stale_ms" => 7_200_000
          }
        })

      assert settings.monitoring.daemon_heartbeat_stale_ms == 7_200_000
    end

    test "Monitoring section rejects non-positive values" do
      {:error, {:invalid_workflow_config, message}} =
        Schema.parse(%{
          "monitoring" => %{
            "daemon_heartbeat_stale_ms" => 0
          }
        })

      assert String.contains?(message, "daemon_heartbeat_stale_ms")
    end

    test "Upgrade section parses with defaults" do
      {:ok, settings} = Schema.parse(%{})
      assert settings.upgrade.check_enabled == true
    end

    test "Upgrade section accepts an explicit opt-out" do
      {:ok, settings} = Schema.parse(%{"upgrade" => %{"check_enabled" => false}})
      assert settings.upgrade.check_enabled == false
    end

    test "Server section parses with defaults" do
      {:ok, settings} = Schema.parse(%{})
      assert settings.server.port == 0
      assert settings.server.host == "127.0.0.1"
    end

    test "Server section accepts explicit values" do
      {:ok, settings} =
        Schema.parse(%{"server" => %{"port" => 4000, "host" => "0.0.0.0"}})

      assert settings.server.port == 4000
      assert settings.server.host == "0.0.0.0"
    end

    test "Opencode section parses with defaults" do
      {:ok, settings} = Schema.parse(%{})
      assert settings.opencode.command == "opencode"
      assert settings.opencode.bridge_port == 4097
      assert settings.opencode.bridge_host == "127.0.0.1"
      assert settings.opencode.model_prefix == "aiur"
      assert settings.opencode.prewarm_disabled == false
    end

    test "Opencode section accepts explicit values" do
      {:ok, settings} =
        Schema.parse(%{
          "opencode" => %{
            "command" => "opencode-custom",
            "bridge_port" => 9000,
            "model_prefix" => "custom"
          }
        })

      assert settings.opencode.command == "opencode-custom"
      assert settings.opencode.bridge_port == 9000
      assert settings.opencode.model_prefix == "custom"
    end
  end

  # FI-CFG-048: max_turns none / unlimited / "" all resolve to nil (uncapped)
end
