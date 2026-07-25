defmodule Aiur.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema
  alias Aiur.Config.Schema.{Polling, StringOrMap}

  describe "agent Mix scheduler cap" do
    test "defaults to four and accepts an explicit override" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.agent.mix_scheduler_cap == 4

      assert {:ok, configured} = Schema.parse(%{"agent" => %{"mix_scheduler_cap" => 3}})
      assert configured.agent.mix_scheduler_cap == 3
    end
  end

  describe "GitHub planning graph bounds" do
    test "the checked-in GitHub workflow fixture satisfies the planning bounds" do
      fixture = Path.expand("../../fixtures/test.aiurconfig", __DIR__)

      assert {:ok, config} = YamlElixir.read_from_file(fixture)
      assert {:ok, settings} = Schema.parse(config)

      assert settings.tracker.github.planning_root_limit == 100
      assert settings.tracker.github.planning_page_budget == 4
      assert settings.tracker.github.planning_call_budget == 4
    end

    test "defaults to finite bounds that permit one hundred roots" do
      assert {:ok, settings} = Schema.parse(%{})

      assert settings.tracker.github.planning_root_limit == 100
      assert settings.tracker.github.planning_page_budget == 4
      assert settings.tracker.github.planning_call_budget == 4
    end

    test "accepts lower positive planning graph bounds" do
      assert {:ok, settings} =
               Schema.parse(%{
                 "tracker" => %{
                   "github" => %{
                     "planning_root_limit" => 25,
                     "planning_page_budget" => 2,
                     "planning_call_budget" => 3
                   }
                 }
               })

      assert settings.tracker.github.planning_root_limit == 25
      assert settings.tracker.github.planning_page_budget == 2
      assert settings.tracker.github.planning_call_budget == 3
    end

    test "rejects zero, negative, non-integer, and over-hard-limit planning graph bounds" do
      invalid = [
        {"planning_root_limit", [0, -1, 101, "infinite"]},
        {"planning_page_budget", [0, -1, 5, "infinite"]},
        {"planning_call_budget", [0, -1, 5, "infinite"]}
      ]

      for {field, values} <- invalid, value <- values do
        assert {:error, {:invalid_workflow_config, message}} =
                 Schema.parse(%{"tracker" => %{"github" => %{field => value}}})

        assert message =~ "tracker.github.#{field}"
      end
    end
  end

  describe "agent rate_limit_fallback" do
    test "defaults to claude" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.agent.rate_limit_fallback == "claude"
    end

    test "rejects a resumable target that could replace the codex session handle" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"agent" => %{"rate_limit_fallback" => "claude-repl"}})

      assert message =~ "rate_limit_fallback"
      assert message =~ "must be \"claude\""
    end

    test "accepts an empty string to disable" do
      assert {:ok, settings} = Schema.parse(%{"agent" => %{"rate_limit_fallback" => ""}})
      assert settings.agent.rate_limit_fallback == ""
    end

    test "rejects codex as the fallback target" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"agent" => %{"rate_limit_fallback" => "codex"}})

      assert message =~ "rate_limit_fallback"
      assert message =~ "must be \"claude\""
    end

    test "rejects an unknown backend" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"agent" => %{"rate_limit_fallback" => "bogus"}})

      assert message =~ "rate_limit_fallback"
      assert message =~ "must be \"claude\""
    end
  end

  describe "agent CI-wait fallback" do
    test "defaults to five minutes and accepts a positive override" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.agent.ci_wait_rewake_minutes == 5

      assert {:ok, configured} =
               Schema.parse(%{"agent" => %{"ci_wait_rewake_minutes" => 9}})

      assert configured.agent.ci_wait_rewake_minutes == 9
    end

    test "rejects zero, negative, and non-integer values with the dotted field path" do
      for value <- [0, -1, "five"] do
        assert {:error, {:invalid_workflow_config, message}} =
                 Schema.parse(%{"agent" => %{"ci_wait_rewake_minutes" => value}})

        assert message =~ "agent.ci_wait_rewake_minutes"
      end
    end
  end

  # FI-CFG-005: StringOrMap cast rejects non-string, non-map values
  describe "StringOrMap" do
    test "casts strings and maps, rejects everything else" do
      assert {:ok, "untrusted"} = StringOrMap.cast("untrusted")
      assert {:ok, %{"type" => "workspaceWrite"}} = StringOrMap.cast(%{"type" => "workspaceWrite"})
      assert :error = StringOrMap.cast(123)
      assert :error = StringOrMap.cast([:list])
      assert :error = StringOrMap.cast(nil)
    end

    test "approval_policy defaults to the string 'untrusted' not a map" do
      {:ok, settings} = Schema.parse(%{})
      assert settings.agent.codex.approval_policy == "untrusted"
      assert is_binary(settings.agent.codex.approval_policy)
    end
  end

  # FI-CFG-031: Polling raises ArgumentError on legacy interval_ms key, not a changeset error
  describe "Polling interval_ms rejection" do
    test "raises ArgumentError on interval_ms string key" do
      assert_raise ArgumentError, ~r/interval_ms is no longer supported/, fn ->
        Schema.parse(%{"polling" => %{"interval_ms" => 1000}})
      end
    end

    test "raises ArgumentError on interval_ms atom key" do
      assert_raise ArgumentError, ~r/interval_ms is no longer supported/, fn ->
        Polling.changeset(%Polling{}, %{interval_ms: 1000})
      end
    end

    test "parses interval_seconds normally" do
      {:ok, settings} = Schema.parse(%{"polling" => %{"interval_seconds" => 60}})
      assert settings.polling.interval_seconds == 60
    end
  end

  # FI-CFG-029 / FI-CFG-035: $ENV token grammar
  describe "env reference grammar" do
    test "$NAME with a valid identifier resolves from the environment" do
      System.put_env("AIUR_TEST_CFG_VAR_123", "/tmp/resolved-root")
      on_exit(fn -> System.delete_env("AIUR_TEST_CFG_VAR_123") end)

      {:ok, settings} =
        Schema.parse(%{"workspace" => %{"root" => "$AIUR_TEST_CFG_VAR_123"}})

      assert settings.workspace.root == "/tmp/resolved-root"
    end

    test "invalid $NAME (starts with digit) passes through as a literal" do
      {:ok, settings} =
        Schema.parse(%{"workspace" => %{"root" => "$123INVALID"}})

      assert settings.workspace.root == "$123INVALID"
    end

    test "invalid $NAME (contains hyphen) passes through as a literal" do
      {:ok, settings} =
        Schema.parse(%{"workspace" => %{"root" => "$MY-VAR"}})

      assert settings.workspace.root == "$MY-VAR"
    end
  end

  # FI-CFG-025: secret resolution – env set / empty-string env → nil / missing env → fallback
  describe "secret resolution" do
    test "linear api_key set in config overrides absent env var" do
      System.delete_env("LINEAR_API_KEY")

      {:ok, settings} =
        Schema.parse(%{"tracker" => %{"linear" => %{"api_key" => "from-config"}}})

      assert settings.tracker.linear.api_key == "from-config"
    end

    test "linear api_key as $ENV_REF resolves from environment" do
      System.put_env("AIUR_TEST_LINEAR_KEY", "env-token")
      on_exit(fn -> System.delete_env("AIUR_TEST_LINEAR_KEY") end)

      {:ok, settings} =
        Schema.parse(%{"tracker" => %{"linear" => %{"api_key" => "$AIUR_TEST_LINEAR_KEY"}}})

      assert settings.tracker.linear.api_key == "env-token"
    end

    test "empty-string env var resolves to nil, not the empty string" do
      System.put_env("AIUR_TEST_LINEAR_KEY", "")
      on_exit(fn -> System.delete_env("AIUR_TEST_LINEAR_KEY") end)

      {:ok, settings} =
        Schema.parse(%{"tracker" => %{"linear" => %{"api_key" => "$AIUR_TEST_LINEAR_KEY"}}})

      assert settings.tracker.linear.api_key == nil
    end

    test "missing env var for $REF falls back to LINEAR_API_KEY env fallback" do
      System.delete_env("AIUR_NONEXISTENT_VAR")
      previous = System.get_env("LINEAR_API_KEY")
      System.put_env("LINEAR_API_KEY", "fallback-value")
      on_exit(fn -> restore_env("LINEAR_API_KEY", previous) end)

      {:ok, settings} =
        Schema.parse(%{"tracker" => %{"linear" => %{"api_key" => "$AIUR_NONEXISTENT_VAR"}}})

      # $AIUR_NONEXISTENT_VAR is missing → falls back to LINEAR_API_KEY env
      assert settings.tracker.linear.api_key == "fallback-value"
    end
  end

  # FI-CFG-035: workspace.root $VAR and empty → tmp default
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
      assert settings.observability.dashboard_writable == true
      assert settings.observability.refresh_ms == 1_000
    end

    test "Observability section accepts explicit values" do
      {:ok, settings} =
        Schema.parse(%{
          "observability" => %{
            "dashboard_enabled" => false,
            "dashboard_writable" => true,
            "refresh_ms" => 500
          }
        })

      assert settings.observability.dashboard_enabled == false
      assert settings.observability.dashboard_writable == true
      assert settings.observability.refresh_ms == 500
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
  describe "max_turns uncapped aliases" do
    test "max_turns 'none' resolves to nil (uncapped)" do
      {:ok, settings} = Schema.parse(%{"agent" => %{"max_turns" => "none"}})
      assert settings.agent.max_turns == nil
    end

    test "max_turns 'unlimited' resolves to nil (uncapped)" do
      {:ok, settings} = Schema.parse(%{"agent" => %{"max_turns" => "unlimited"}})
      assert settings.agent.max_turns == nil
    end

    test "max_turns empty string resolves to nil (uncapped)" do
      {:ok, settings} = Schema.parse(%{"agent" => %{"max_turns" => ""}})
      assert settings.agent.max_turns == nil
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
