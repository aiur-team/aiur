defmodule Aiur.Config.AgentSettingsTest do
  use Aiur.TestSupport
  alias Aiur.CodingAgent
  alias Aiur.Config.{RoutingValue, Schema}
  alias Aiur.Config.Schema.{AgentValidation, Codex, StringOrMap}
  alias Ecto.Changeset

  test "an explicit model override beats the routing model for the same backend" do
    # The add-agent modal writes `complexity:N` beside `model:<backend>-<variant>`,
    # so an operator picking a model for the *routed* backend used to be silently
    # discarded in favour of the routing model. An explicitly pinned variant wins.
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "codex",
      agent_routing: %{4 => "claude:sonnet", 5 => "codex:gpt-5.5"}
    )

    pinned = %Issue{labels: ["complexity:4", "model:claude-opus-4-8"]}
    assert CodingAgent.backend_for(pinned) == "claude"
    assert CodingAgent.model_for(pinned) == "opus-4-8"

    # A family alias stays a floating alias here; only resolve_model/2 widens it,
    # so the override must not be frozen into a version pin at this layer.
    # claude resolves its own aliases (:native), so "opus" also survives
    # resolve_model/2 untouched.
    family = %Issue{labels: ["complexity:4", "model:claude-opus"]}
    assert CodingAgent.model_for(family) == "opus"
    assert CodingAgent.resolve_model("claude", CodingAgent.model_for(family)) == "opus"

    # codex derives its aliases, so the same override survives model_for/1 as an
    # alias and is widened to a concrete version only at resolve_model/2 — the
    # half of the pipeline that knows which backends need it.
    codex_family = %Issue{labels: ["complexity:5", "model:codex-sol"]}
    assert CodingAgent.model_for(codex_family) == "sol"
    assert CodingAgent.resolve_model("codex", "sol") =~ ~r/^gpt-[\d.]+-sol$/

    pinned_codex = %Issue{labels: ["complexity:5", "model:codex-gpt-5.6-sol"]}
    assert CodingAgent.model_for(pinned_codex) == "gpt-5.6-sol"

    # Preserved: a bare override names only a backend, so the routing value for
    # that same backend remains the more specific answer.
    bare = %Issue{labels: ["complexity:4", "model:claude"]}
    assert CodingAgent.backend_for(bare) == "claude"
    assert CodingAgent.model_for(bare) == "sonnet"

    # Preserved: a bare override for a backend routing never names pins nothing,
    # so resolve_model/2 supplies that backend's own default.
    elsewhere = %Issue{labels: ["complexity:4", "model:codex"]}
    assert CodingAgent.model_for(elsewhere) == nil
  end

  test "the label set the add-agent modal writes keeps the picked model and effort" do
    # AgentRoutingPreview.plan/2 emits complexity + model:<backend>-<variant> +
    # model:<effort> together, so that whole triple is what dispatch actually
    # sees. The variant must survive routing, and the effort label must still
    # apply even though the backend override suppresses the routed effort.
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      agent_routing: %{3 => "codex:gpt-5.5:low", 4 => "codex::high"}
    )

    modal = %Issue{labels: ["complexity:3", "model:codex-gpt-5.6-sol", "model:high"]}
    assert CodingAgent.backend_for(modal) == "codex"
    assert CodingAgent.model_for(modal) == "gpt-5.6-sol"
    assert CodingAgent.effort_for(modal) == "high"

    # A routing value with no model segment is the remaining path into the
    # bare-override branch: it defers to routing, and routing pins nothing.
    effort_only = %Issue{labels: ["complexity:4", "model:codex"]}
    assert CodingAgent.model_for(effort_only) == nil
  end

  test "remote_control opt-in defaults OFF and parses an explicit true" do
    # Setting #2 is orthogonal to :kind; the default is the single flip
    # point for always-remote, so a fresh parse must land on false.
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.agent.remote_control == false

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{remote_control: true}})

    assert settings.agent.remote_control == true
  end

  test "max_log_history_mb defaults to 1000 and validates positivity" do
    # The retention sweep reads this cap; an unset config must land on the
    # built-in 1000 MB default, an explicit value must round-trip, and a
    # non-positive cap must be rejected (it would wipe everything).
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.max_log_history_mb == 1000

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, max_log_history_mb: 250})

    assert settings.max_log_history_mb == 250

    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(%{tracker: %{kind: "memory"}, max_log_history_mb: 0})
  end

  test "agent.max_load_average defaults to protected, casts integers, preserves explicit disable" do
    # The CPU load gate (#465) is default-on: an absent key must yield the
    # conservative per-scheduler threshold, an explicit YAML null must still
    # disable the gate, an explicit value must round-trip as a float, a
    # YAML-written integer must cast (not error), and a non-positive threshold
    # must be rejected (it would stall all dispatch).
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.agent.max_load_average == 1.5

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{max_load_average: nil}})

    assert settings.agent.max_load_average == nil

    # Real YAML loads arrive string-keyed; the explicit null must survive
    # drop_nil_values on that production shape too, not just the atom-keyed map.
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "agent" => %{"max_load_average" => nil}
             })

    assert settings.agent.max_load_average == nil

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{max_load_average: 1.5}})

    assert settings.agent.max_load_average == 1.5

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{max_load_average: 2}})

    assert settings.agent.max_load_average == 2.0

    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{max_load_average: 0}})
  end

  test "agent.min_free_memory_mb is optional and accepts only a positive floor" do
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.agent.min_free_memory_mb == nil

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               agent: %{min_free_memory_mb: 4_096}
             })

    assert settings.agent.min_free_memory_mb == 4_096

    for invalid <- [0, -1, "invalid"] do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{
                 tracker: %{kind: "memory"},
                 agent: %{min_free_memory_mb: invalid}
               })

      assert message =~ "agent.min_free_memory_mb"
    end
  end

  test "agent.build_start_stagger_seconds defaults off and validates a non-negative interval" do
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.agent.build_start_stagger_seconds == 0

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               agent: %{build_start_stagger_seconds: 5}
             })

    assert settings.agent.build_start_stagger_seconds == 5

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               agent: %{build_start_stagger_seconds: 0}
             })

    assert settings.agent.build_start_stagger_seconds == 0

    for invalid <- [-1, "invalid"] do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{
                 tracker: %{kind: "memory"},
                 agent: %{build_start_stagger_seconds: invalid}
               })

      assert message =~ "agent.build_start_stagger_seconds"
    end
  end

  test "agent load envelope defaults safely, validates tuning, and preserves explicit disable" do
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.agent.target_load_average == 1.0
    assert settings.agent.load_ramp_step == 1
    assert settings.agent.load_cooldown_seconds == 60
    assert settings.agent.capacity_starvation_alert_after_seconds == 60

    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "agent" => %{
                 "target_load_average" => nil,
                 "load_ramp_step" => 3,
                 "load_cooldown_seconds" => 0,
                 "capacity_starvation_alert_after_seconds" => 300
               }
             })

    assert settings.agent.target_load_average == nil
    assert settings.agent.max_load_average == 1.5
    assert settings.agent.load_ramp_step == 3
    assert settings.agent.load_cooldown_seconds == 0
    assert settings.agent.capacity_starvation_alert_after_seconds == 300

    for invalid_agent <- [
          %{target_load_average: 0},
          %{target_load_average: -1},
          %{load_ramp_step: 0},
          %{load_ramp_step: -1},
          %{load_cooldown_seconds: -1},
          %{capacity_starvation_alert_after_seconds: 0},
          %{capacity_starvation_alert_after_seconds: -1}
        ] do
      assert {:error, {:invalid_workflow_config, _}} =
               Schema.parse(%{tracker: %{kind: "memory"}, agent: invalid_agent})
    end
  end

  test "broker-timeout retry-rate signal keys default safely and validate tuning (#2464)" do
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.agent.budget_broker_rate_window_seconds == 300
    assert settings.agent.budget_broker_degraded_retry_threshold == 5
    assert settings.agent.budget_broker_degraded_alert_after_seconds == 60

    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "agent" => %{
                 "budget_broker_rate_window_seconds" => 120,
                 "budget_broker_degraded_retry_threshold" => 3,
                 "budget_broker_degraded_alert_after_seconds" => 300
               }
             })

    assert settings.agent.budget_broker_rate_window_seconds == 120
    assert settings.agent.budget_broker_degraded_retry_threshold == 3
    assert settings.agent.budget_broker_degraded_alert_after_seconds == 300

    for invalid_agent <- [
          %{budget_broker_rate_window_seconds: 0},
          %{budget_broker_rate_window_seconds: -1},
          %{budget_broker_degraded_retry_threshold: 0},
          %{budget_broker_degraded_retry_threshold: -1},
          %{budget_broker_degraded_alert_after_seconds: 0},
          %{budget_broker_degraded_alert_after_seconds: -1}
        ] do
      assert {:error, {:invalid_workflow_config, _}} =
               Schema.parse(%{tracker: %{kind: "memory"}, agent: invalid_agent})
    end
  end

  test "agent.synthetic_load_process_cap defaults to derived nil and validates non-negative" do
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.agent.synthetic_load_process_cap == nil

    assert Aiur.Config.default_synthetic_load_process_cap(12) == 3
    assert Aiur.Config.default_synthetic_load_process_cap(2) == 1

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{synthetic_load_process_cap: 0}})

    assert settings.agent.synthetic_load_process_cap == 0

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{synthetic_load_process_cap: 5}})

    assert settings.agent.synthetic_load_process_cap == 5

    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{synthetic_load_process_cap: -1}})
  end

  test "prewarm defaults to disabled and validates timeout and poll settings" do
    # Pre-warm is opt-in: an absent block must yield disabled + no base_build +
    # no polling (byte-for-byte back-compat), an explicit block must round-trip,
    # and a negative poll interval must be rejected.
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.prewarm.enabled == false
    assert settings.prewarm.base_build == nil
    assert settings.prewarm.poll_seconds == 0
    assert settings.prewarm.build_timeout_minutes == 60

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               prewarm: %{enabled: true, base_build: "mise exec -- mix compile", poll_seconds: 30, build_timeout_minutes: 90}
             })

    assert settings.prewarm.enabled == true
    assert settings.prewarm.base_build == "mise exec -- mix compile"
    assert settings.prewarm.poll_seconds == 30
    assert settings.prewarm.build_timeout_minutes == 90

    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(%{tracker: %{kind: "memory"}, prewarm: %{poll_seconds: -1}})

    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(%{tracker: %{kind: "memory"}, prewarm: %{build_timeout_minutes: 0}})
  end

  test "alerts default to enabled with OS sounds off (back-compat) and round-trip overrides" do
    # Back-compat hard requirement: a machine with no `alerts:` section keeps
    # playing its existing .aiur/alerts + ~/alerts sounds, so the defaults must be
    # enabled + OS-default sounds OFF. An explicit block must round-trip.
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.alerts.enabled == true
    assert settings.alerts.use_os_default_sounds == false
    assert settings.alerts.sound_dir == nil
    assert settings.alerts.alerts_file == nil

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               alerts: %{
                 enabled: false,
                 use_os_default_sounds: true,
                 sound_dir: "~/alerts",
                 alerts_file: "alerts.yaml"
               }
             })

    assert settings.alerts.enabled == false
    assert settings.alerts.use_os_default_sounds == true
    assert settings.alerts.sound_dir == "~/alerts"
    assert settings.alerts.alerts_file == "alerts.yaml"
  end

  test "debug defaults to false and parses an explicit true" do
    # `debug: true` is the config-driven equivalent of the `--debug` flag;
    # an unset config must stay off, an explicit true must round-trip.
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.debug == false

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, debug: true})

    assert settings.debug == true
  end

  test "agent.max_agent_duration_minutes defaults to 60 and rejects negatives" do
    # Safety-checkpoint cap the orchestrator's overrun watchdog reads; 0 disables.
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.agent.max_agent_duration_minutes == 60

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{max_agent_duration_minutes: 0}})

    assert settings.agent.max_agent_duration_minutes == 0

    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{max_agent_duration_minutes: -1}})
  end

  test "complexity prompts normalize string levels and reject bad levels/values" do
    assert AgentValidation.normalize_complexity_prompts(nil) == %{}

    assert AgentValidation.normalize_complexity_prompts(%{"3" => "medium guidance", 5 => "be careful"}) ==
             %{
               3 => "medium guidance",
               5 => "be careful"
             }

    good =
      {%{}, %{complexity_prompts: :map}}
      |> Changeset.cast(%{complexity_prompts: %{3 => "guidance"}}, [:complexity_prompts])
      |> AgentValidation.validate_complexity_prompts(:complexity_prompts)

    assert good.errors == []

    bad =
      {%{}, %{complexity_prompts: :map}}
      |> Changeset.cast(%{complexity_prompts: %{0 => "x", 4 => 99}}, [:complexity_prompts])
      |> AgentValidation.validate_complexity_prompts(:complexity_prompts)

    assert {:complexity_prompts, {"complexity levels must be positive integers", []}} in bad.errors
    assert {:complexity_prompts, {"complexity prompt values must be strings", []}} in bad.errors
  end

  test "max_turns_by_complexity normalizes string levels and rejects bad levels/values" do
    assert AgentValidation.normalize_max_turns_by_complexity(nil) == %{}

    assert AgentValidation.normalize_max_turns_by_complexity(%{"1" => 3, 5 => 12}) ==
             %{1 => 3, 5 => 12}

    good =
      {%{}, %{max_turns_by_complexity: :map}}
      |> Changeset.cast(%{max_turns_by_complexity: %{1 => 3}}, [:max_turns_by_complexity])
      |> AgentValidation.validate_max_turns_by_complexity(:max_turns_by_complexity)

    assert good.errors == []

    bad =
      {%{}, %{max_turns_by_complexity: :map}}
      |> Changeset.cast(%{max_turns_by_complexity: %{0 => 3, 4 => 0}}, [:max_turns_by_complexity])
      |> AgentValidation.validate_max_turns_by_complexity(:max_turns_by_complexity)

    assert {:max_turns_by_complexity, {"complexity levels must be positive integers", []}} in bad.errors

    assert {:max_turns_by_complexity, {"max_turns_by_complexity values must be positive integers", []}} in bad.errors
  end
end
