defmodule Aiur.BuildQueue.Hints do
  @moduledoc """
  Read-only dispatch hints from the build queue's ETS table.

  The queue server owns rows `{issue_id, {downstream_rank, position}, held?, trigger, depth}`.
  Without the table or a row, dispatch keeps its ordinary ordering and eligibility.
  """

  alias Aiur.BuildQueue.Settings

  @table :aiur_build_queue_hints
  @sets_table :aiur_build_queue_sets

  @spec table_name() :: atom()
  def table_name, do: @table

  @spec publish_sets(map()) :: true
  def publish_sets(snapshot) do
    if :ets.whereis(@sets_table) == :undefined, do: :ets.new(@sets_table, [:named_table, :set, :protected, read_concurrency: true])
    :ets.insert(@sets_table, {:snapshot, snapshot})
  end

  @spec sets() :: map() | nil
  def sets do
    case :ets.lookup(@sets_table, :snapshot) do
      [{:snapshot, snapshot}] -> snapshot
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec sort_key(String.t()) :: {integer(), non_neg_integer()}
  def sort_key(issue_id), do: elem(lookup(issue_id), 0)

  @spec held?(String.t()) :: boolean()
  def held?(issue_id), do: elem(lookup(issue_id), 1)

  @spec trigger_for(String.t()) :: Aiur.StartTrigger.trigger()
  def trigger_for(issue_id), do: elem(lookup(issue_id), 2) || Settings.start_trigger(Aiur.Config.settings!())

  @spec critical_rank(String.t()) :: {non_neg_integer(), non_neg_integer()} | nil
  def critical_rank(issue_id) do
    case :ets.lookup(@table, issue_id) do
      [{^issue_id, {downstream, _}, _, _, depth}] -> {depth, -downstream}
      [{^issue_id, {downstream, _}, _, _}] -> {0, -downstream}
      [{^issue_id, {downstream, _}, _}] -> {0, -downstream}
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec observation_max_age_ms() :: pos_integer()
  def observation_max_age_ms, do: Settings.observation_max_age_ms(Aiur.Config.settings!())

  defp lookup(issue_id) do
    case :ets.lookup(@table, issue_id) do
      [{^issue_id, sort_key, held?, trigger, _depth}] -> {sort_key, held?, trigger}
      [{^issue_id, sort_key, held?, trigger}] -> {sort_key, held?, trigger}
      [{^issue_id, sort_key, held?}] -> {sort_key, held?, nil}
      [] -> {{0, 0}, false, nil}
    end
  rescue
    # The queue is disabled or its owning server has stopped.
    ArgumentError -> {{0, 0}, false, nil}
  end
end
