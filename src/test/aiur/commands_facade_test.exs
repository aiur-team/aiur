defmodule Aiur.CommandsFacadeTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands

  @renamed %{
    override_rows: {Aiur.Commands.OverridePresentation, :rows},
    pending_override_status: {Aiur.Commands.OverridePresentation, :pending},
    notify_override_merge: {Aiur.DecisionStore.OverrideMerges, :notify},
    override_successor: {Aiur.Commands.CorrectiveTicket, :successor},
    override_target_ticket: {Aiur.Commands.Overrides, :target_ticket},
    pending_override: {Aiur.Commands.Overrides, :pending},
    pending_resume_override: {Aiur.Commands.Overrides, :resume_request},
    prepare_override_prompt: {Aiur.Commands.OverridePrompt, :prepare},
    render_pending_overrides: {Aiur.Commands.OverridePrompt, :render},
    record_override_prompt_receipt: {Aiur.Commands.OverridePrompt, :received},
    override_dispatchable?: {Aiur.DecisionStore.Overrides, :dispatchable?},
    requester_notified: {Aiur.Commands.ExecutorDelivery, :on_enqueued},
    public_v2: {Aiur.Commands.Projection, :public_v2},
    needs_you?: {Aiur.Commands.Routing.Policy, :needs_you?},
    matches_route?: {Aiur.Commands.Routing.Policy, :matches_route?},
    capability_ids: {Aiur.DecisionStore.CapabilityProvider, :capability_ids},
    capabilities: {Aiur.DecisionStore.CapabilityProvider, :capabilities},
    query_list: {Aiur.DecisionQuery, :list},
    list_decisions: {Aiur.DecisionStore, :list},
    decision_stale_topic: {Aiur.DecisionAttentionSignals, :stale_topic},
    query_get: {Aiur.DecisionQuery, :get},
    query_counts: {Aiur.DecisionQuery, :counts},
    default_store: {Aiur.DecisionQuery, :default_store},
    history: {Aiur.DecisionHistory, :list},
    subscribe: {Aiur.DecisionPubSub, :subscribe},
    validate_asks: {Aiur.Asks, :validate_events},
    open_asks: {Aiur.Asks, :open},
    create_ask: {Aiur.Asks, :create},
    resolve_ask: {Aiur.Asks, :resolve},
    all_asks: {Aiur.Asks, :all},
    metrics_snapshot: {Aiur.DecisionMetrics, :snapshot},
    metrics_snapshots: {Aiur.DecisionMetrics, :snapshots},
    attention_correlation: {Aiur.DecisionAttention, :correlation},
    open_attention_with_decision: {Aiur.DecisionAttention, :open_with_decision},
    resolve_attention: {Aiur.DecisionAttention, :resolve},
    classify_supervisor_token: {Aiur.SupervisorToken, :classify},
    errors: {Aiur.SupervisorToken.EnvCheck, :errors},
    open?: {Aiur.DecisionStore.RetainedIndex, :open?},
    print_projection_status: {Aiur.DecisionStore.ProjectionRecovery, :print_status},
    default_metrics: {Aiur.Commands.Defaults, :default_metrics},
    default_attention: {Aiur.Commands.Defaults, :default_attention},
    default_api: {Aiur.Commands.Defaults, :default_api},
    sanitize_ticket: {Aiur.DecisionSanitizer, :ticket},
    sanitize_source: {Aiur.DecisionSanitizer, :source},
    sanitize_actor: {Aiur.DecisionSanitizer, :actor},
    sanitize_artifacts: {Aiur.DecisionSanitizer, :artifacts},
    sanitize_dispatch_attempt: {Aiur.DecisionSanitizer, :dispatch_attempt},
    sanitize_lifecycle_fact: {Aiur.DecisionSanitizer, :lifecycle_fact},
    sanitize_follow_ups: {Aiur.DecisionSanitizer, :follow_ups},
    sanitize_provenance: {Aiur.DecisionSanitizer, :provenance}
  }

  test "future regression guard: every facade function has an exported target" do
    for {fun, arity} <- Commands.__info__(:functions) do
      {target, target_fun} = Map.get(@renamed, fun, {Aiur.DecisionStore, fun})
      Code.ensure_loaded!(target)
      assert function_exported?(target, target_fun, arity), "#{inspect(target)}.#{target_fun}/#{arity}"
    end
  end

  test "blocked_ticket_ids/1 through the facade reports store_unavailable for a dead store" do
    assert Commands.blocked_ticket_ids(:commands_facade_test_dead_store) == {:error, :store_unavailable}
  end

  test "facade defaults preserve the existing process and API module names" do
    assert Commands.default_store() == Aiur.DecisionStore
    assert Commands.default_metrics() == Aiur.DecisionMetrics
    assert Commands.default_attention() == Aiur.DecisionAttention
    assert Commands.default_api() == Aiur.DecisionApi
  end
end
