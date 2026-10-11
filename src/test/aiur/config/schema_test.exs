defmodule Aiur.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema

  describe "Claude account configuration" do
    test "defaults to legacy single-account behavior and accepts selection modes" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.agent.accounts == %{}
      assert defaults.agent.account_selection == "balance"

      assert {:ok, configured} =
               Schema.parse(%{
                 "agent" => %{
                   "accounts" => %{"claude" => ["default", "max"]},
                   "account_selection" => "priority"
                 }
               })

      assert configured.agent.accounts["claude"] == ["default", "max"]
      assert configured.agent.account_selection == "priority"
    end

    test "rejects malformed account lists and unknown selection modes" do
      assert {:error, _} = Schema.parse(%{"agent" => %{"accounts" => %{"claude" => "max"}}})
      assert {:error, _} = Schema.parse(%{"agent" => %{"account_selection" => "random"}})
    end
  end

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
    test "Muse config accepts native settings and rejects invalid trust and approval values" do
      assert {:ok, settings} =
               Schema.parse(%{
                 "agent" => %{
                   "priority" => ["muse"],
                   "backend_configs" => %{
                     "muse" => %{
                       "command" => "muse serve",
                       "trust_workspace" => true,
                       "approval_mode" => "onRequest",
                       "model" => "muse-spark-1.3-contributor"
                     }
                   }
                 }
               })

      assert settings.agent.backend_configs["muse"]["trust_workspace"] == true

      for invalid <- [%{"trust_workspace" => "true"}, %{"approval_mode" => "always"}, %{"unsupported" => true}] do
        assert {:error, {:invalid_workflow_config, message}} =
                 Schema.parse(%{"agent" => %{"backend_configs" => %{"muse" => invalid}}})

        assert message =~ "muse"
      end
    end

    test "rejects the obsolete root Codex section with a migration hint" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"codex" => %{"approval_policy" => "never"}})

      assert message =~ "workflow root"
      assert message =~ "agent.codex"
    end

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

    test "accepts a non-default primary with the registered fallback" do
      assert {:ok, settings} =
               Schema.parse(%{"agent" => %{"rate_limit_primary" => "codex", "rate_limit_fallback" => "claude"}})

      assert settings.agent.rate_limit_primary == "codex"
      assert settings.agent.rate_limit_fallback == "claude"
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
end
