defmodule Aiur.GitHub.DependencyCache do
  @moduledoc """
  Process-local cache for GitHub dependency hydration.

  The named ETS table lets successive orchestrator polls share results without
  making the cache part of orchestrator state. Entries are scoped by repository
  (or a test namespace), and the table is created by the polling process before
  any hydration tasks start so its lifetime follows that long-lived owner.
  """

  @table __MODULE__

  @type entry :: %{
          blockers: [map()],
          checked_at_ms: integer(),
          source_updated_at: DateTime.t() | nil
        }

  @spec get(term(), String.t()) :: entry() | nil
  def get(namespace, issue_id) when is_binary(issue_id) do
    ensure_table()

    case :ets.lookup(@table, {:entry, namespace, issue_id}) do
      [{{:entry, ^namespace, ^issue_id}, entry}] -> entry
      [] -> nil
    end
  end

  @spec put(term(), String.t(), entry()) :: :ok
  def put(namespace, issue_id, entry) when is_binary(issue_id) and is_map(entry) do
    ensure_table()
    true = :ets.insert(@table, {{:entry, namespace, issue_id}, entry})
    :ok
  end

  @spec active_backoff(term(), integer()) :: term() | nil
  def active_backoff(namespace, now_ms) when is_integer(now_ms) do
    ensure_table()

    case :ets.lookup(@table, {:backoff, namespace}) do
      [{{:backoff, ^namespace}, %{until_ms: until_ms, reason: reason}}]
      when is_integer(until_ms) and until_ms > now_ms ->
        reason

      [_expired] ->
        :ets.delete(@table, {:backoff, namespace})
        nil

      [] ->
        nil
    end
  end

  @spec put_backoff(term(), integer(), term()) :: :ok
  def put_backoff(namespace, until_ms, reason) when is_integer(until_ms) do
    ensure_table()
    true = :ets.insert(@table, {{:backoff, namespace}, %{until_ms: until_ms, reason: reason}})
    :ok
  end

  @doc false
  @spec clear(term()) :: :ok
  def clear(namespace) do
    ensure_table()
    :ets.match_delete(@table, {{:entry, namespace, :_}, :_})
    :ets.delete(@table, {:backoff, namespace})
    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> create_table()
      _table -> @table
    end
  end

  defp create_table do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])
  rescue
    ArgumentError -> @table
  end
end
