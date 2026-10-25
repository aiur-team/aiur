defmodule Aiur.DecisionStore.Reads do
  @moduledoc false

  alias Aiur.Decision
  alias Aiur.DecisionEvent
  alias Aiur.DecisionStore.Audit

  @recent_decision_limit 50

  @doc """
  Returns the set of ticket identifiers that currently have an open blocking
  Command, from one serialized store snapshot.

  A Decision gates dispatch when it is both `blocking` and still open or
  deferred. Internal delivery/persistence alerts are deliberately excluded,
  mirroring `Aiur.DecisionStore.RetainedIndex.operator_command?/1`.
  """
  @spec blocked_ticket_ids(GenServer.server()) ::
          {:ok, MapSet.t(String.t())} | {:error, :store_unavailable}
  def blocked_ticket_ids(server \\ Aiur.DecisionStore) do
    GenServer.call(server, :blocked_ticket_ids)
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  @doc """
  Returns open blocking Command ids for the requested tickets in one store call.
  """
  @spec open_blocking_decision_ids([String.t()], GenServer.server(), timeout()) ::
          {:ok, [String.t()]} | {:error, :store_unavailable}
  def open_blocking_decision_ids(ticket_identifiers, server \\ Aiur.DecisionStore, timeout \\ 1_000)
      when is_list(ticket_identifiers) do
    GenServer.call(server, {:open_blocking_decision_ids, ticket_identifiers}, timeout)
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  @doc "Returns open blocking Command ids grouped by ticket identifier in one store call."
  @spec open_blocking_decision_ids_by_ticket([String.t()], GenServer.server(), timeout()) ::
          {:ok, %{optional(String.t()) => [String.t()]}} | {:error, :store_unavailable}
  def open_blocking_decision_ids_by_ticket(
        ticket_identifiers,
        server \\ Aiur.DecisionStore,
        timeout \\ 1_000
      )
      when is_list(ticket_identifiers) do
    GenServer.call(server, {:open_blocking_decision_ids_by_ticket, ticket_identifiers}, timeout)
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  @doc "Returns whether an optional agent question explains a ticket's self-pause."
  @spec nonblocking_question_pause?(String.t(), GenServer.server(), timeout()) ::
          {:ok, boolean()} | {:error, :store_unavailable}
  def nonblocking_question_pause?(ticket_identifier, server \\ Aiur.DecisionStore, timeout \\ 100)
      when is_binary(ticket_identifier) do
    GenServer.call(server, {:nonblocking_question_pause, ticket_identifier}, timeout)
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  @doc "Returns the bounded dashboard window, prioritizing unresolved and blocking Decisions."
  @spec recent_decisions(non_neg_integer(), GenServer.server()) :: [Decision.t()]
  def recent_decisions(limit \\ @recent_decision_limit, server \\ Aiur.DecisionStore)
      when is_integer(limit) and limit >= 0 do
    GenServer.call(server, {:recent_decisions, min(limit, @recent_decision_limit)})
  end

  @spec history(String.t(), GenServer.server()) :: {:ok, [Decision.t()]} | {:error, :not_found}
  def history(decision_id, server \\ Aiur.DecisionStore) when is_binary(decision_id) do
    GenServer.call(server, {:history, decision_id})
  end

  @doc "Returns every Decision's immutable history in audit order in one serialized read."
  @spec all_history(GenServer.server()) :: %{String.t() => [Decision.t()]}
  def all_history(server \\ Aiur.DecisionStore) do
    GenServer.call(server, :all_history)
  end

  @doc "Returns every Decision's complete immutable audit history in one serialized read."
  @spec all_audit_history(GenServer.server()) :: %{
          String.t() => [Decision.t() | DecisionEvent.t()]
        }
  def all_audit_history(server \\ Aiur.DecisionStore) do
    GenServer.call(server, :all_audit_history)
  end

  @doc "Returns a bounded newest-first audit window with projection contexts."
  @spec recent_audit_history(non_neg_integer(), GenServer.server()) :: %{
          records: [Decision.t() | DecisionEvent.t()],
          contexts: map(),
          actions: map(),
          revisions: map()
        }
  def recent_audit_history(limit \\ Audit.recent_limit(), server \\ Aiur.DecisionStore)
      when is_integer(limit) and limit >= 0 do
    GenServer.call(server, {:recent_audit_history, min(limit, Audit.recent_limit())})
  end

  @doc "Complete ordered audit history, including request and lifecycle events."
  @spec audit_history(String.t(), GenServer.server()) ::
          {:ok, [Decision.t() | DecisionEvent.t()]} | {:error, :not_found}
  def audit_history(decision_id, server \\ Aiur.DecisionStore) when is_binary(decision_id) do
    GenServer.call(server, {:audit_history, decision_id})
  end

  @doc "`:writable`, `{:projection_stale, since}`, or a journal read-only/unavailable reason."
  @spec health(GenServer.server()) :: :writable | tuple()
  def health(server \\ Aiur.DecisionStore) do
    GenServer.call(server, :health)
  end
end
