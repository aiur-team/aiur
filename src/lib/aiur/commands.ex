defmodule Aiur.Commands do
  @moduledoc """
  Public entry point for Commands and Asks.

  The existing Decision services retain persistence, validation and delivery
  ownership; this facade preserves their arguments and results. All supported
  arities stay together so the public delegation contract is easy to audit.
  """

  @spec agent_lifecycle(:acknowledged | :resolved, map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate agent_lifecycle(type, payload, opts), to: Aiur.DecisionStore

  @spec agent_lifecycle(:acknowledged | :resolved, map(), keyword(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  defdelegate agent_lifecycle(type, payload, opts, server), to: Aiur.DecisionStore

  @spec all_asks(String.t()) :: {:ok, [Aiur.Asks.ask()]} | {:error, term()}
  defdelegate all_asks(repo), to: Aiur.Asks, as: :all

  @spec answer(String.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate answer(decision_id, payload), to: Aiur.DecisionStore

  @spec answer(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate answer(decision_id, payload, opts), to: Aiur.DecisionStore

  @spec answer(String.t(), map(), keyword(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  defdelegate answer(decision_id, payload, opts, server), to: Aiur.DecisionStore

  @spec answer(String.t(), map(), keyword(), GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  defdelegate answer(decision_id, payload, opts, server, timeout), to: Aiur.DecisionStore

  @spec attention_correlation(Aiur.Issue.t(), String.t()) :: {:ok, %{source_id: String.t(), legacy_attention: map()}} | {:error, term()}
  defdelegate attention_correlation(issue, slug), to: Aiur.DecisionAttention, as: :correlation

  @spec blocked_ticket_ids() :: {:ok, MapSet.t(String.t())} | {:error, :store_unavailable}
  defdelegate blocked_ticket_ids(), to: Aiur.DecisionStore

  @spec blocked_ticket_ids(GenServer.server()) :: {:ok, MapSet.t(String.t())} | {:error, :store_unavailable}
  defdelegate blocked_ticket_ids(server), to: Aiur.DecisionStore

  @spec classify_supervisor_token(term()) :: Aiur.SupervisorToken.classification()
  defdelegate classify_supervisor_token(token), to: Aiur.SupervisorToken, as: :classify

  @spec create_ask(String.t(), map()) :: {:ok, Aiur.Asks.ask()} | {:error, term()}
  defdelegate create_ask(repo, attrs), to: Aiur.Asks, as: :create

  @spec default_api() :: module()
  defdelegate default_api(), to: Aiur.Commands.Defaults

  @spec default_attention() :: module()
  defdelegate default_attention(), to: Aiur.Commands.Defaults

  @spec default_metrics() :: module()
  defdelegate default_metrics(), to: Aiur.Commands.Defaults

  @spec default_store() :: module()
  defdelegate default_store(), to: Aiur.DecisionQuery

  @spec defer(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate defer(decision_id), to: Aiur.DecisionStore

  @spec defer(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate defer(decision_id, opts), to: Aiur.DecisionStore

  @spec defer(String.t(), keyword(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  defdelegate defer(decision_id, opts, server), to: Aiur.DecisionStore

  @spec defer(String.t(), keyword(), GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  defdelegate defer(decision_id, opts, server, timeout), to: Aiur.DecisionStore

  @spec deliver_pending_answers(String.t()) :: :ok
  defdelegate deliver_pending_answers(ticket_identifier), to: Aiur.DecisionStore

  @spec deliver_pending_answers(String.t(), GenServer.server()) :: :ok
  defdelegate deliver_pending_answers(ticket_identifier, server), to: Aiur.DecisionStore

  @spec dismiss(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate dismiss(decision_id), to: Aiur.DecisionStore

  @spec dismiss(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate dismiss(decision_id, opts), to: Aiur.DecisionStore

  @spec dismiss(String.t(), keyword(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  defdelegate dismiss(decision_id, opts, server), to: Aiur.DecisionStore

  @spec dismiss(String.t(), keyword(), GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  defdelegate dismiss(decision_id, opts, server, timeout), to: Aiur.DecisionStore

  @spec enrich_attention(map()) :: {:ok, Aiur.DecisionStore.accept_result()} | {:error, term()}
  defdelegate enrich_attention(payload), to: Aiur.DecisionStore

  @spec enrich_attention(map(), keyword()) :: {:ok, Aiur.DecisionStore.accept_result()} | {:error, term()}
  defdelegate enrich_attention(payload, opts), to: Aiur.DecisionStore

  @spec enrich_attention(map(), keyword(), GenServer.server()) :: {:ok, Aiur.DecisionStore.accept_result()} | {:error, term()}
  defdelegate enrich_attention(payload, opts, server), to: Aiur.DecisionStore

  @spec enrich_attention(map(), keyword(), GenServer.server(), timeout()) :: {:ok, Aiur.DecisionStore.accept_result()} | {:error, term()}
  defdelegate enrich_attention(payload, opts, server, timeout), to: Aiur.DecisionStore

  @spec errors(map()) :: [String.t()]
  defdelegate errors(env), to: Aiur.SupervisorToken.EnvCheck

  @spec escalate_executor_command(String.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate escalate_executor_command(decision_id, payload), to: Aiur.DecisionStore

  @spec escalate_executor_command(String.t(), map(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  defdelegate escalate_executor_command(decision_id, payload, server), to: Aiur.DecisionStore

  @spec escalate_executor_command(String.t(), map(), GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  defdelegate escalate_executor_command(decision_id, payload, server, timeout), to: Aiur.DecisionStore

  @spec handle_revision_follow_up(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate handle_revision_follow_up(decision_id, action_id), to: Aiur.DecisionStore

  @spec handle_revision_follow_up(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate handle_revision_follow_up(decision_id, action_id, opts), to: Aiur.DecisionStore

  @spec handle_revision_follow_up(String.t(), String.t(), keyword(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  defdelegate handle_revision_follow_up(decision_id, action_id, opts, server), to: Aiur.DecisionStore

  @spec handle_revision_follow_up(String.t(), String.t(), keyword(), GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  defdelegate handle_revision_follow_up(decision_id, action_id, opts, server, timeout), to: Aiur.DecisionStore

  @spec history() :: [map()]
  defdelegate history(), to: Aiur.DecisionHistory, as: :list

  @spec history(keyword()) :: [map()]
  defdelegate history(opts), to: Aiur.DecisionHistory, as: :list

  @spec metrics_snapshot(String.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate metrics_snapshot(decision_id), to: Aiur.DecisionMetrics, as: :snapshot

  @spec metrics_snapshot(String.t(), GenServer.server()) :: {:ok, map()} | {:error, :not_found}
  defdelegate metrics_snapshot(decision_id, server), to: Aiur.DecisionMetrics, as: :snapshot

  @spec metrics_snapshots() :: %{String.t() => map()}
  defdelegate metrics_snapshots(), to: Aiur.DecisionMetrics, as: :snapshots

  @spec metrics_snapshots(GenServer.server()) :: %{String.t() => map()}
  defdelegate metrics_snapshots(server), to: Aiur.DecisionMetrics, as: :snapshots

  @spec moot(String.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate moot(decision_id, payload), to: Aiur.DecisionStore

  @spec moot(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate moot(decision_id, payload, opts), to: Aiur.DecisionStore

  @spec moot(String.t(), map(), keyword(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  defdelegate moot(decision_id, payload, opts, server), to: Aiur.DecisionStore

  @spec moot(String.t(), map(), keyword(), GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  defdelegate moot(decision_id, payload, opts, server, timeout), to: Aiur.DecisionStore

  @spec nonblocking_question_pause?(String.t()) :: {:ok, boolean()} | {:error, :store_unavailable}
  defdelegate nonblocking_question_pause?(ticket_identifier), to: Aiur.DecisionStore

  @spec nonblocking_question_pause?(String.t(), GenServer.server()) :: {:ok, boolean()} | {:error, :store_unavailable}
  defdelegate nonblocking_question_pause?(ticket_identifier, server), to: Aiur.DecisionStore

  @spec nonblocking_question_pause?(String.t(), GenServer.server(), timeout()) :: {:ok, boolean()} | {:error, :store_unavailable}
  defdelegate nonblocking_question_pause?(ticket_identifier, server, timeout), to: Aiur.DecisionStore

  @spec open_asks(String.t()) :: {:ok, [Aiur.Asks.ask()]} | {:error, term()}
  defdelegate open_asks(repo), to: Aiur.Asks, as: :open

  @spec open_attention_with_decision(Aiur.Issue.t(), Path.t() | nil, String.t() | nil, String.t(), String.t(), keyword()) :: {:ok, Aiur.DecisionStore.accept_result()} | {:error, term()}
  defdelegate open_attention_with_decision(issue, workspace, worker_host, slug, question, opts), to: Aiur.DecisionAttention, as: :open_with_decision

  @spec open_attention_with_decision(GenServer.server(), Aiur.Issue.t(), Path.t() | nil, String.t() | nil, String.t(), String.t(), keyword()) ::
          {:ok, Aiur.DecisionStore.accept_result()} | {:error, term()}
  defdelegate open_attention_with_decision(server, issue, workspace, worker_host, slug, question, opts), to: Aiur.DecisionAttention, as: :open_with_decision

  @spec open_blocking_decision_ids([String.t()]) :: {:ok, [String.t()]} | {:error, :store_unavailable}
  defdelegate open_blocking_decision_ids(ticket_identifiers), to: Aiur.DecisionStore

  @spec open_blocking_decision_ids([String.t()], GenServer.server()) :: {:ok, [String.t()]} | {:error, :store_unavailable}
  defdelegate open_blocking_decision_ids(ticket_identifiers, server), to: Aiur.DecisionStore

  @spec open_blocking_decision_ids([String.t()], GenServer.server(), timeout()) :: {:ok, [String.t()]} | {:error, :store_unavailable}
  defdelegate open_blocking_decision_ids(ticket_identifiers, server, timeout), to: Aiur.DecisionStore

  @spec print_projection_status() :: :ok
  defdelegate print_projection_status(), to: Aiur.DecisionStore.ProjectionRecovery, as: :print_status

  @spec print_projection_status(GenServer.server()) :: :ok
  defdelegate print_projection_status(store), to: Aiur.DecisionStore.ProjectionRecovery, as: :print_status

  @spec query_counts() :: {:ok, map()}
  defdelegate query_counts(), to: Aiur.DecisionQuery, as: :counts

  @spec query_counts(keyword()) :: {:ok, map()}
  defdelegate query_counts(opts), to: Aiur.DecisionQuery, as: :counts

  @spec query_get(String.t()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :store_unavailable
             | {:indeterminate, map()}
             | {:invalid_decision_id, atom()}}
  defdelegate query_get(decision_id), to: Aiur.DecisionQuery, as: :get

  @spec query_get(String.t(), keyword()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :store_unavailable
             | {:indeterminate, map()}
             | {:invalid_decision_id, atom()}}
  defdelegate query_get(decision_id, opts), to: Aiur.DecisionQuery, as: :get

  @spec query_list() :: {:ok, map()} | {:error, {:invalid_query, term()}}
  defdelegate query_list(), to: Aiur.DecisionQuery, as: :list

  @spec query_list(map()) :: {:ok, map()} | {:error, {:invalid_query, term()}}
  defdelegate query_list(params), to: Aiur.DecisionQuery, as: :list

  @spec query_list(map(), keyword()) :: {:ok, map()} | {:error, {:invalid_query, term()}}
  defdelegate query_list(params, opts), to: Aiur.DecisionQuery, as: :list

  @spec recent_decisions() :: [Aiur.Decision.t()]
  defdelegate recent_decisions(), to: Aiur.DecisionStore

  @spec recent_decisions(non_neg_integer()) :: [Aiur.Decision.t()]
  defdelegate recent_decisions(limit), to: Aiur.DecisionStore

  @spec recent_decisions(non_neg_integer(), GenServer.server()) :: [Aiur.Decision.t()]
  defdelegate recent_decisions(limit, server), to: Aiur.DecisionStore

  @spec record_delivery(map()) :: {:ok, :accepted | :duplicate | :ignored} | {:error, term()}
  defdelegate record_delivery(item), to: Aiur.DecisionStore

  @spec record_delivery(map(), GenServer.server()) :: {:ok, :accepted | :duplicate | :ignored} | {:error, term()}
  defdelegate record_delivery(item, server), to: Aiur.DecisionStore

  @spec record_transport_batch_async(:restored | :consumed | :failed, [map()]) :: :ok
  defdelegate record_transport_batch_async(type, items), to: Aiur.DecisionStore

  @spec record_transport_batch_async(:restored | :consumed | :failed, [map()], term()) :: :ok
  defdelegate record_transport_batch_async(type, items, reason), to: Aiur.DecisionStore

  @spec record_transport_batch_async(:restored | :consumed | :failed, [map()], term(), GenServer.server()) :: :ok
  defdelegate record_transport_batch_async(type, items, reason, server), to: Aiur.DecisionStore

  @spec request(map()) :: {:ok, Aiur.DecisionStore.accept_result()} | {:error, term()}
  defdelegate request(payload), to: Aiur.DecisionStore

  @spec request(map(), keyword()) :: {:ok, Aiur.DecisionStore.accept_result()} | {:error, term()}
  defdelegate request(payload, opts), to: Aiur.DecisionStore

  @spec request(map(), keyword(), GenServer.server()) :: {:ok, Aiur.DecisionStore.accept_result()} | {:error, term()}
  defdelegate request(payload, opts, server), to: Aiur.DecisionStore

  @spec request(map(), keyword(), GenServer.server(), timeout()) :: {:ok, Aiur.DecisionStore.accept_result()} | {:error, term()}
  defdelegate request(payload, opts, server, timeout), to: Aiur.DecisionStore

  @spec resolve_ask(String.t(), String.t()) :: {:ok, Aiur.Asks.ask()} | {:error, term()}
  defdelegate resolve_ask(repo, id), to: Aiur.Asks, as: :resolve

  @spec resolve_ask(String.t(), String.t(), String.t() | nil) :: {:ok, Aiur.Asks.ask()} | {:error, term()}
  defdelegate resolve_ask(repo, id, note), to: Aiur.Asks, as: :resolve

  @spec resolve_attention(Aiur.Issue.t(), String.t()) :: :ok
  defdelegate resolve_attention(issue, slug), to: Aiur.DecisionAttention, as: :resolve

  @spec resolve_attention(GenServer.server(), Aiur.Issue.t(), String.t()) :: :ok
  defdelegate resolve_attention(server, issue, slug), to: Aiur.DecisionAttention, as: :resolve

  @spec retry_dispatch(String.t(), String.t()) :: {:ok, :scheduled | :already_dispatching} | {:error, term()}
  defdelegate retry_dispatch(decision_id, action_id), to: Aiur.DecisionStore

  @spec retry_dispatch(String.t(), String.t(), GenServer.server()) :: {:ok, :scheduled | :already_dispatching} | {:error, term()}
  defdelegate retry_dispatch(decision_id, action_id, server), to: Aiur.DecisionStore

  @spec revise(String.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate revise(decision_id, payload), to: Aiur.DecisionStore

  @spec revise(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate revise(decision_id, payload, opts), to: Aiur.DecisionStore

  @spec revise(String.t(), map(), keyword(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  defdelegate revise(decision_id, payload, opts, server), to: Aiur.DecisionStore

  @spec revise(String.t(), map(), keyword(), GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  defdelegate revise(decision_id, payload, opts, server, timeout), to: Aiur.DecisionStore

  @spec sanitize_actor(map() | term()) :: %{kind: term()} | nil
  defdelegate sanitize_actor(actor), to: Aiur.DecisionSanitizer, as: :actor

  @spec sanitize_artifacts(list() | term()) :: [map()]
  defdelegate sanitize_artifacts(artifacts), to: Aiur.DecisionSanitizer, as: :artifacts

  @spec sanitize_dispatch_attempt(map() | term()) :: map()
  defdelegate sanitize_dispatch_attempt(attempt), to: Aiur.DecisionSanitizer, as: :dispatch_attempt

  @spec sanitize_follow_ups(map()) :: map()
  defdelegate sanitize_follow_ups(follow_ups), to: Aiur.DecisionSanitizer, as: :follow_ups

  @spec sanitize_lifecycle_fact(map() | nil) :: map() | nil
  defdelegate sanitize_lifecycle_fact(fact), to: Aiur.DecisionSanitizer, as: :lifecycle_fact

  @spec sanitize_provenance(map() | term()) :: map() | nil
  defdelegate sanitize_provenance(provenance), to: Aiur.DecisionSanitizer, as: :provenance

  @spec sanitize_source(map()) :: %{agent_id: String.t() | nil}
  defdelegate sanitize_source(source), to: Aiur.DecisionSanitizer, as: :source

  @spec sanitize_ticket(map()) :: map()
  defdelegate sanitize_ticket(ticket), to: Aiur.DecisionSanitizer, as: :ticket

  @spec subscribe() :: :ok | {:error, term()}
  defdelegate subscribe(), to: Aiur.DecisionPubSub

  @spec supersede(String.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate supersede(decision_id, payload), to: Aiur.DecisionStore

  @spec supersede(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate supersede(decision_id, payload, opts), to: Aiur.DecisionStore

  @spec supersede(String.t(), map(), keyword(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  defdelegate supersede(decision_id, payload, opts, server), to: Aiur.DecisionStore

  @spec supersede(String.t(), map(), keyword(), GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  defdelegate supersede(decision_id, payload, opts, server, timeout), to: Aiur.DecisionStore

  @spec validate_asks([map()]) :: :ok | {:error, {pos_integer(), term()}}
  defdelegate validate_asks(events), to: Aiur.Asks, as: :validate_events

  @spec validate_delivery(map()) :: {:ok, :accepted | :ignored} | {:error, term()}
  defdelegate validate_delivery(item), to: Aiur.DecisionStore

  @spec validate_delivery(map(), GenServer.server()) :: {:ok, :accepted | :ignored} | {:error, term()}
  defdelegate validate_delivery(item, server), to: Aiur.DecisionStore
  @spec capability_ids() :: [String.t()]
  defdelegate capability_ids(), to: Aiur.DecisionStore.CapabilityProvider

  @spec capabilities(Aiur.Capabilities.Provider.context()) :: map()
  defdelegate capabilities(context), to: Aiur.DecisionStore.CapabilityProvider
end
