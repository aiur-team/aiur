defmodule Aiur.CommandsFacadeTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands

  @renamed %{
    query_list: {Aiur.DecisionQuery, :list},
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
