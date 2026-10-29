defmodule Aiur.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema
  alias Aiur.Config.Schema.{Agent, BuildOrder, Decisions, Events, Experiments, Github, Voice}

  test "tracks every nested schema source as a compile resource" do
    schema_directory = Path.expand("../../../lib/aiur/config/schema", __DIR__)

    resources =
      external_resources(Schema)

    nested_sources = Path.wildcard(Path.join(schema_directory, "*.ex")) |> Enum.map(&Path.expand/1)

    assert nested_sources != []
    assert Enum.all?(nested_sources, &(&1 in resources))
  end

  test "nested embed modules track external child schema sources" do
    schema_directory = Path.expand("../../../lib/aiur/config/schema", __DIR__)

    expected_sources = [
      {Decisions, ["decisions_escalation.ex"]},
      {Events, ["events_export.ex"]},
      {Agent, ["codex.ex", "git_identity.ex", "pricing_policy.ex"]},
      {Github, ["github_app.ex", "github_credential.ex"]},
      {Experiments, ["experiments_analyst.ex", "experiments_auto.ex"]},
      {BuildOrder, ["general_epic.ex"]},
      {Voice, ["voice_conversation.ex"]}
    ]

    for {module, sources} <- expected_sources do
      resources = external_resources(module)

      for source <- sources do
        assert Path.join(schema_directory, source) in resources,
               "#{inspect(module)} must track #{source}"
      end
    end

    assert {:ok, parsed} = Schema.parse(%{})
    assert parsed.decisions.escalation.enabled
    assert parsed.events.export.retention_days == 7
  end

  test "incremental Mix compilation refreshes a three-level embedded default" do
    fixture = Path.join(System.tmp_dir!(), "aiur-schema-compile-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(fixture) end)

    create_incremental_compile_fixture!(
      fixture,
      tracks_source?(Schema, "decisions.ex"),
      tracks_source?(Schema, "decisions_escalation.ex"),
      tracks_source?(Decisions, "decisions_escalation.ex")
    )

    assert {_, 0} = compile_fixture(fixture)
    assert fixture_default(fixture) == "true"

    leaf_source = Path.join(fixture, "lib/schema/escalation.ex")
    File.write!(leaf_source, String.replace(File.read!(leaf_source), "default: true", "default: false"))

    assert {output, 0} = compile_fixture(fixture)
    assert output =~ "Compiling 3 files"
    assert fixture_default(fixture) == "false"
  end

  defp external_resources(module) do
    module.__info__(:attributes)
    |> Keyword.get_values(:external_resource)
    |> List.flatten()
    |> Enum.map(&Path.expand/1)
  end

  defp tracks_source?(module, relative_path) do
    schema_directory = Path.expand("../../../lib/aiur/config/schema", __DIR__)
    Path.join(schema_directory, relative_path) in external_resources(module)
  end

  defp create_incremental_compile_fixture!(fixture, root_tracks_middle_source?, root_tracks_leaf_source?, middle_tracks_leaf_source?) do
    ecto = Path.expand("../../../deps/ecto", __DIR__)
    decimal = Path.expand("../../../deps/decimal", __DIR__)
    telemetry = Path.expand("../../../deps/telemetry", __DIR__)

    root_resources =
      [
        if(root_tracks_middle_source?, do: ~S|@external_resource "lib/schema/decisions.ex"|),
        if(root_tracks_leaf_source?, do: ~S|@external_resource "lib/schema/escalation.ex"|)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    middle_resource = if middle_tracks_leaf_source?, do: ~S|@external_resource "lib/schema/escalation.ex"|, else: ""

    File.mkdir_p!(Path.join(fixture, "lib/schema"))

    File.write!(Path.join(fixture, "mix.exs"), """
    defmodule SchemaFixture.MixProject do
      use Mix.Project
      def project, do: [app: :schema_fixture, version: "0.1.0", elixir: "~> 1.19", deps: [
        {:ecto, path: #{inspect(ecto)}, override: true},
        {:decimal, path: #{inspect(decimal)}, override: true},
        {:telemetry, path: #{inspect(telemetry)}, override: true}
      ]]
      def application, do: [extra_applications: [:logger]]
    end
    """)

    File.write!(Path.join(fixture, "lib/schema/escalation.ex"), """
    defmodule SchemaFixture.Escalation do
      use Ecto.Schema
      embedded_schema do
        field :enabled, :boolean, default: true
      end
    end
    """)

    File.write!(Path.join(fixture, "lib/schema/decisions.ex"), """
    defmodule SchemaFixture.Decisions do
      #{middle_resource}
      use Ecto.Schema
      embedded_schema do
        embeds_one :escalation, SchemaFixture.Escalation, defaults_to_struct: true
      end
    end
    """)

    File.write!(Path.join(fixture, "lib/schema.ex"), """
    defmodule SchemaFixture do
      #{root_resources}
      use Ecto.Schema
      embedded_schema do
        embeds_one :decisions, SchemaFixture.Decisions, defaults_to_struct: true
      end
      def parse, do: Ecto.Changeset.cast(%__MODULE__{}, %{}, []) |> Ecto.Changeset.apply_changes()
      def default, do: parse().decisions.escalation.enabled
    end
    """)
  end

  defp compile_fixture(fixture) do
    System.cmd("mix", ["compile"], cd: fixture)
  end

  defp fixture_default(fixture) do
    {output, 0} = System.cmd("mix", ["run", "--no-start", "-e", "IO.write(SchemaFixture.default())"], cd: fixture)
    String.trim(output)
  end

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

  describe "native compaction config" do
    test "accepts Codex opt-in and rejects every other provider" do
      assert {:ok, settings} = Schema.parse(%{"compaction" => %{"enabled" => true, "backends" => ["codex"], "manual_approval" => true}})
      assert settings.compaction.enabled
      assert settings.compaction.backends == ["codex"]
      assert settings.compaction.manual_approval

      assert {:ok, threshold_settings} = Schema.parse(%{"compaction" => %{"enabled" => true, "backends" => ["codex"], "auto_trigger" => %{"enabled" => true, "token_threshold" => 75_000}}})
      assert threshold_settings.compaction.auto_trigger.enabled
      assert threshold_settings.compaction.auto_trigger.token_threshold == 75_000

      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"compaction" => %{"backends" => ["claude"]}})
      assert message =~ "only for 'codex'"
    end

    test "rejects non-positive compaction RPC timeout" do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"compaction" => %{"timeout_ms" => 0}})
      assert message =~ "timeout_ms"
    end

    test "rejects a token threshold below the supported minimum" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"compaction" => %{"auto_trigger" => %{"enabled" => true, "token_threshold" => 999}}})

      assert message =~ "token_threshold"
    end
  end

  test "operator relay defaults off and must be explicitly enabled" do
    assert {:ok, defaults} = Schema.parse(%{})
    assert defaults.executor.relay_operator_answers == false
    assert {:ok, enabled} = Schema.parse(%{"executor" => %{"relay_operator_answers" => true}})
    assert enabled.executor.relay_operator_answers == true
    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"executor" => %{"relay_operator_answers" => "yes please"}})
    assert message =~ "relay_operator_answers"
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

  describe "non-closing merge triage marker" do
    test "defaults to needs-triage and accepts a non-empty override" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.agent.non_closing_merge_marker == "needs-triage"
      assert {:ok, configured} = Schema.parse(%{"agent" => %{"non_closing_merge_marker" => "review-later"}})
      assert configured.agent.non_closing_merge_marker == "review-later"
    end
  end

  describe "agent CI recovery limits" do
    test "defaults on with bounded per-poll and hourly reruns, accepts false" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.agent.ci_recovery_enabled
      assert defaults.agent.ci_recovery_max_per_poll == 5
      assert defaults.agent.ci_recovery_max_per_hour == 20

      assert {:ok, configured} = Schema.parse(%{"agent" => %{"ci_recovery_enabled" => false}})
      refute configured.agent.ci_recovery_enabled
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
