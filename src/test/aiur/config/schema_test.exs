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

  describe "agent saturation sentinel" do
    test "defaults to enabled and accepts an explicit opt-out" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.agent.saturation_log_enabled == true

      assert {:ok, configured} = Schema.parse(%{"agent" => %{"saturation_log_enabled" => false}})
      assert configured.agent.saturation_log_enabled == false
    end
  end

  describe "host-pressure admission defaults" do
    test "max_concurrent_agents defaults nil (derived from host capacity) and run_queue_threshold is opt-in" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.agent.max_concurrent_agents == nil
      assert defaults.agent.run_queue_threshold == nil
    end

    test "accepts explicit max_concurrent_agents and run_queue_threshold" do
      assert {:ok, settings} =
               Schema.parse(%{"agent" => %{"max_concurrent_agents" => 4, "run_queue_threshold" => 1.5}})

      assert settings.agent.max_concurrent_agents == 4
      assert settings.agent.run_queue_threshold == 1.5
    end

    test "rejects a non-positive run_queue_threshold" do
      assert {:error, _} = Schema.parse(%{"agent" => %{"run_queue_threshold" => 0}})
      assert {:error, _} = Schema.parse(%{"agent" => %{"run_queue_threshold" => -1.0}})
    end
  end

  describe "agent backend config sections" do
    test "retains an arbitrary registry-named backend section" do
      assert {:ok, settings} =
               Schema.parse(%{
                 "agent" => %{"backend_configs" => %{"fake" => %{"command" => "fake-agent --serve", "region" => "test"}}}
               })

      assert settings.agent.backend_configs["fake"] == %{"command" => "fake-agent --serve", "region" => "test"}
    end

    test "DeepSeek routing requires an explicit backend opt-in" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"agent" => %{"routing" => %{"5" => "deepseek"}}})

      assert message =~ "disabled backend"

      assert {:ok, settings} =
               Schema.parse(%{
                 "agent" => %{
                   "priority" => ["deepseek"],
                   "routing" => %{"5" => "deepseek"}
                 }
               })

      assert settings.agent.routing[5] == "deepseek"
    end
  end

  describe "agent priority" do
    test "defaults empty and accepts an ordered list" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.agent.priority == []

      assert {:ok, settings} = Schema.parse(%{"agent" => %{"priority" => ["deepseek", "codex", "claude"]}})
      assert settings.agent.priority == ["deepseek", "codex", "claude"]
    end

    test "rejects duplicate or unknown backends" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"agent" => %{"priority" => ["codex", "codex"]}})

      assert message =~ "duplicate"

      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"agent" => %{"priority" => ["nonesuch"]}})

      assert message =~ "unknown backend"
    end
  end

  describe "prior-work continuation" do
    test "defaults on for cold backend handoff and remains configurable" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.agent.prior_work_continuation == true

      assert {:ok, disabled} = Schema.parse(%{"agent" => %{"prior_work_continuation" => false}})
      assert disabled.agent.prior_work_continuation == false
    end
  end

  describe "GitHub planning graph bounds" do
    test "the checked-in GitHub workflow fixture satisfies the planning bounds" do
      fixture = Path.expand("../../fixtures/test.yaml", __DIR__)

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

  describe "GitHub shared request budget" do
    test "defaults to a conservative shared ceiling and accepts explicit tuning" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.tracker.github.max_inflight == 4
      assert defaults.tracker.github.max_inflight_per_endpoint == 2
      assert defaults.tracker.github.requests_per_minute == 120
      assert defaults.tracker.github.stagger_ms == 75

      assert {:ok, settings} =
               Schema.parse(%{
                 "tracker" => %{
                   "github" => %{
                     "max_inflight" => 8,
                     "max_inflight_per_endpoint" => 3,
                     "requests_per_minute" => 240,
                     "stagger_ms" => 125
                   }
                 }
               })

      assert settings.tracker.github.max_inflight == 8
      assert settings.tracker.github.max_inflight_per_endpoint == 3
      assert settings.tracker.github.requests_per_minute == 240
      assert settings.tracker.github.stagger_ms == 125
    end

    test "defaults per-actor hourly ceilings and accepts explicit tuning" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.tracker.github.daemon_core_limit_per_hour == 3000
      assert defaults.tracker.github.daemon_graphql_limit_per_hour == 4500
      assert defaults.tracker.github.daemon_search_limit_per_hour == 600
      assert defaults.tracker.github.agent_core_limit_per_hour == 250
      assert defaults.tracker.github.agent_graphql_limit_per_hour == 600
      assert defaults.tracker.github.agent_search_limit_per_hour == 600

      assert {:ok, settings} =
               Schema.parse(%{
                 "tracker" => %{
                   "github" => %{
                     "daemon_core_limit_per_hour" => 2000,
                     "daemon_graphql_limit_per_hour" => 1500,
                     "daemon_search_limit_per_hour" => 900,
                     "agent_core_limit_per_hour" => 600,
                     "agent_graphql_limit_per_hour" => 300,
                     "agent_search_limit_per_hour" => 450
                   }
                 }
               })

      assert settings.tracker.github.daemon_core_limit_per_hour == 2000
      assert settings.tracker.github.daemon_graphql_limit_per_hour == 1500
      assert settings.tracker.github.daemon_search_limit_per_hour == 900
      assert settings.tracker.github.agent_core_limit_per_hour == 600
      assert settings.tracker.github.agent_graphql_limit_per_hour == 300
      assert settings.tracker.github.agent_search_limit_per_hour == 450
    end

    test "rejects a negative per-actor hourly ceiling" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{
                 "tracker" => %{"github" => %{"agent_core_limit_per_hour" => -1}}
               })

      assert message =~ "tracker.github.agent_core_limit_per_hour"
    end

    test "rejects an endpoint ceiling above the shared ceiling" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"tracker" => %{"github" => %{"max_inflight" => 2, "max_inflight_per_endpoint" => 3}}})

      assert message =~ "tracker.github.max_inflight_per_endpoint"
      assert message =~ "must not exceed max_inflight"
    end
  end

  describe "GitHub dispatch allowlist" do
    test "accepts explicit GitHub logins and defaults to an empty explicit list" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.tracker.github.allowed_users == []

      assert {:ok, settings} =
               Schema.parse(%{
                 "tracker" => %{
                   "github" => %{"allowed_users" => ["its-everdred", "its-applekid"]}
                 }
               })

      assert settings.tracker.github.allowed_users == ["its-everdred", "its-applekid"]
    end

    test "rejects blank dispatch allowlist entries" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"tracker" => %{"github" => %{"allowed_users" => [""]}}})

      assert message =~ "tracker.github.allowed_users"
    end
  end

  describe "GitHub human merger allowlist" do
    test "accepts explicit human GitHub logins and defaults to deny all" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.tracker.github.human_mergers == []

      assert {:ok, settings} =
               Schema.parse(%{
                 "tracker" => %{
                   "github" => %{"human_mergers" => ["its-everdred"]}
                 }
               })

      assert settings.tracker.github.human_mergers == ["its-everdred"]
    end

    test "rejects blank human merger allowlist entries" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"tracker" => %{"github" => %{"human_mergers" => [""]}}})

      assert message =~ "tracker.github.human_mergers"
    end
  end

  describe "GitHub identity_mode" do
    test "defaults to separate_account so an existing install is unchanged" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.tracker.github.identity_mode == "separate_account"
    end

    test "accepts single_account" do
      assert {:ok, settings} =
               Schema.parse(%{"tracker" => %{"github" => %{"identity_mode" => "single_account"}}})

      assert settings.tracker.github.identity_mode == "single_account"
    end

    test "rejects any other spelling rather than silently picking a mode" do
      # Which mode is in effect decides which comments wake an agent, so a typo
      # must fail loudly at config load, not resolve to a guess.
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"tracker" => %{"github" => %{"identity_mode" => "single"}}})

      assert message =~ "tracker.github.identity_mode"
    end
  end

  describe "agent rate_limit_fallback" do
    test "defaults to claude" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.agent.rate_limit_fallback == "claude"
    end

    test "rejects claude-repl as a resumable fallback target" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"agent" => %{"rate_limit_fallback" => "claude-repl"}})

      assert message =~ "rate_limit_fallback"
      assert message =~ "eligible registered fallback backend"
    end

    test "accepts a non-default eligible primary/fallback pair" do
      assert {:ok, settings} =
               Schema.parse(%{"agent" => %{"rate_limit_primary" => "claude", "rate_limit_fallback" => "fake"}})

      assert settings.agent.rate_limit_primary == "claude"
      assert settings.agent.rate_limit_fallback == "fake"
    end

    test "accepts an empty string to disable" do
      assert {:ok, settings} = Schema.parse(%{"agent" => %{"rate_limit_fallback" => ""}})
      assert settings.agent.rate_limit_fallback == ""
    end

    test "rejects a fallback equal to the primary" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"agent" => %{"rate_limit_fallback" => "codex"}})

      assert message =~ "rate_limit_fallback"
      assert message =~ "must differ from rate_limit_primary"
    end

    test "rejects codex as a resumable fallback target" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"agent" => %{"rate_limit_primary" => "claude", "rate_limit_fallback" => "codex"}})

      assert message =~ "eligible registered fallback backend"
    end

    test "rejects an unknown backend" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"agent" => %{"rate_limit_fallback" => "bogus"}})

      assert message =~ "rate_limit_fallback"
      assert message =~ "must be a registered backend"
    end

    test "rejects an unknown primary backend" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"agent" => %{"rate_limit_primary" => "bogus"}})

      assert message =~ "rate_limit_primary"
      assert message =~ "must be a registered backend"
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

      assert {:ok, %{"type" => "workspaceWrite"}} =
               StringOrMap.cast(%{"type" => "workspaceWrite"})

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

    # The poll loop's GitHub spend is fixed cost that scales as 1/interval, so
    # the default is what most fleets actually pay. At 30s it exceeded GitHub's
    # whole 5,000 point/hour budget on its own. An operator who configures a
    # tighter interval still gets it; only the unset case is widened.
    test "interval_seconds defaults to the widened 120s" do
      {:ok, unset} = Schema.parse(%{})
      assert unset.polling.interval_seconds == 120

      {:ok, empty_section} = Schema.parse(%{"polling" => %{}})
      assert empty_section.polling.interval_seconds == 120

      {:ok, tightened} = Schema.parse(%{"polling" => %{"interval_seconds" => 15}})
      assert tightened.polling.interval_seconds == 15
    end

    test "idle_widen_factor defaults to 5 and can only widen polling" do
      {:ok, unset} = Schema.parse(%{})
      assert unset.polling.idle_widen_factor == 5.0

      {:ok, configured} = Schema.parse(%{"polling" => %{"idle_widen_factor" => 8}})
      assert configured.polling.idle_widen_factor == 8.0

      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"polling" => %{"idle_widen_factor" => 0.5}})

      assert message =~ "polling.idle_widen_factor"
      assert message =~ "between 1.0 and 100.0"

      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"polling" => %{"idle_widen_factor" => 1.0e100}})

      assert message =~ "polling.idle_widen_factor"
    end

    # Measured: the provider usage endpoint serves roughly one request per two
    # minutes. Below that the excess is rejected and the meters quietly stop
    # updating, so the floor is enforced rather than merely documented.
    test "usage_interval_seconds is floored at the endpoint's real limit" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"polling" => %{"usage_interval_seconds" => 60}})

      assert message =~ "polling.usage_interval_seconds"
      assert message =~ "at least 120 seconds"

      assert {:error, _} = Schema.parse(%{"polling" => %{"usage_interval_seconds" => 119}})

      {:ok, settings} = Schema.parse(%{"polling" => %{"usage_interval_seconds" => 120}})
      assert settings.polling.usage_interval_seconds == 120
    end

    # Per-class cadences (#2309): `polling.intervals` names a class and
    # overrides `interval_seconds` for that class only. The map is optional and
    # empty by default, so existing configs keep today's single-interval
    # behaviour.
    test "intervals defaults to an empty map" do
      {:ok, settings} = Schema.parse(%{})
      assert settings.polling.intervals == %{}
    end

    test "intervals accepts a per-class map of positive seconds" do
      {:ok, settings} =
        Schema.parse(%{
          "polling" => %{
            "interval_seconds" => 120,
            "intervals" => %{"dispatch" => 120, "planning" => 600, "review" => 300}
          }
        })

      assert settings.polling.intervals == %{"dispatch" => 120, "planning" => 600, "review" => 300}
    end

    test "intervals accepts 0 as the on-demand (no timer) value" do
      {:ok, settings} =
        Schema.parse(%{
          "polling" => %{"intervals" => %{"planning" => 0, "firehose" => 0}}
        })

      assert settings.polling.intervals == %{"planning" => 0, "firehose" => 0}
    end

    test "intervals rejects an unknown class" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"polling" => %{"intervals" => %{"plannning" => 600}}})

      assert message =~ "unknown poll class"
      assert message =~ "planning"
    end

    test "intervals rejects a negative value" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"polling" => %{"intervals" => %{"planning" => -1}}})

      assert message =~ "planning"
      assert message =~ "non-negative"
    end

    # Review feedback #2309 (finding 1): `dispatch` now binds the tick, so `0`
    # there is not an on-demand value — it would stop the scheduler (an
    # immediate-reschedule busy loop). The schema rejects it outright rather
    # than silently falling back, so the dead-config failure mode is impossible.
    test "intervals rejects dispatch: 0 (the dispatch tick must always run)" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"polling" => %{"intervals" => %{"dispatch" => 0}}})

      assert message =~ "dispatch"
      assert message =~ "positive"

      {:ok, settings} = Schema.parse(%{"polling" => %{"intervals" => %{"dispatch" => 60}}})
      assert settings.polling.intervals == %{"dispatch" => 60}
    end

    test "usage_interval_seconds defaults above the floor" do
      {:ok, settings} = Schema.parse(%{})
      assert settings.polling.usage_interval_seconds == 300
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

  describe "elevenlabs voice-input section" do
    setup do
      previous = System.get_env("ELEVENLABS_API_KEY")
      System.delete_env("ELEVENLABS_API_KEY")
      on_exit(fn -> restore_env("ELEVENLABS_API_KEY", previous) end)
      :ok
    end

    test "defaults to no key and the ISO-639-3 English language code when the section is absent" do
      assert {:ok, settings} = Schema.parse(%{})

      assert settings.elevenlabs.api_key == nil
      assert settings.elevenlabs.enabled == true
      assert settings.elevenlabs.language_code == "eng"
      assert settings.elevenlabs.voice_id == nil
    end

    test "parses an explicit section" do
      assert {:ok, settings} =
               Schema.parse(%{"elevenlabs" => %{"api_key" => "from-config", "language_code" => "spa", "voice_id" => "voice-123"}})

      assert settings.elevenlabs.api_key == "from-config"
      assert settings.elevenlabs.enabled == true
      assert settings.elevenlabs.language_code == "spa"
      assert settings.elevenlabs.voice_id == "voice-123"
    end

    test "$ELEVENLABS_API_KEY resolves from the environment" do
      System.put_env("ELEVENLABS_API_KEY", "env-token")

      assert {:ok, settings} = Schema.parse(%{"elevenlabs" => %{"api_key" => "$ELEVENLABS_API_KEY"}})

      assert settings.elevenlabs.api_key == "env-token"
    end

    test "an explicit config value wins over the ELEVENLABS_API_KEY env var" do
      System.put_env("ELEVENLABS_API_KEY", "env-token")

      assert {:ok, settings} = Schema.parse(%{"elevenlabs" => %{"api_key" => "from-config"}})

      assert settings.elevenlabs.api_key == "from-config"
    end

    test "the env var supplies the key when the section omits it" do
      System.put_env("ELEVENLABS_API_KEY", "env-token")

      assert {:ok, settings} = Schema.parse(%{"elevenlabs" => %{"language_code" => "eng"}})

      assert settings.elevenlabs.api_key == "env-token"
    end

    test "explicit disablement suppresses configured and fallback credentials" do
      System.put_env("ELEVENLABS_API_KEY", "env-token")

      assert {:ok, settings} =
               Schema.parse(%{"elevenlabs" => %{"enabled" => false, "api_key" => "from-config"}})

      assert settings.elevenlabs.enabled == false
      assert settings.elevenlabs.api_key == nil

      assert {:ok, fallback_settings} = Schema.parse(%{"elevenlabs" => %{"enabled" => false}})
      assert fallback_settings.elevenlabs.api_key == nil
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
      assert settings.observability.telemetry_enabled == true
      assert settings.observability.telemetry_retention_max_bytes == 64 * 1024 * 1024
      assert settings.observability.telemetry_retention_max_age_days == 30
      assert settings.observability.telemetry_retention_prune_interval_bytes == nil
    end

    test "Observability section accepts explicit values" do
      {:ok, settings} =
        Schema.parse(%{
          "observability" => %{
            "dashboard_enabled" => false,
            "dashboard_writable" => true,
            "refresh_ms" => 500,
            "telemetry_enabled" => false,
            "telemetry_retention_max_bytes" => 1_024,
            "telemetry_retention_max_age_days" => 7,
            "telemetry_retention_prune_interval_bytes" => 128
          }
        })

      assert settings.observability.dashboard_enabled == false
      assert settings.observability.dashboard_writable == true
      assert settings.observability.refresh_ms == 500
      assert settings.observability.telemetry_enabled == false
      assert settings.observability.telemetry_retention_max_bytes == 1_024
      assert settings.observability.telemetry_retention_max_age_days == 7
      assert settings.observability.telemetry_retention_prune_interval_bytes == 128
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
