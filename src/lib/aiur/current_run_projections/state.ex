defmodule Aiur.CurrentRunProjections.State do
  @moduledoc false

  alias Aiur.{CurrentRunMembership, CurrentRunOutcomeSnapshot, CurrentRunSummary}
  alias Aiur.CurrentRunOutcomeSnapshot.MembershipIndex
  alias Aiur.CurrentRunProjections.{Checkpoint, UnitsBuilder}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Orchestrator.StatusReport
  alias AiurWeb.OperatorControlCenter.UnitsRow

  @spec new(keyword()) :: map()
  def new(opts) do
    named? = Keyword.get(opts, :name, Aiur.CurrentRunProjections) != nil
    sources = empty_sources()
    units = UnitsBuilder.empty(sources.membership)

    state = %{
      readers: readers(opts),
      membership_index_fun: Keyword.get(opts, :membership_index_fun, &MembershipIndex.build/1),
      units_snapshot_fun: Keyword.get(opts, :units_snapshot_fun, &UnitsRow.snapshot/1),
      pubsub: Keyword.get(opts, :pubsub, Aiur.PubSub),
      task_supervisor: Keyword.get(opts, :task_supervisor, Aiur.TaskSupervisor),
      source_timeout_ms: positive_integer(opts, :source_timeout_ms, 5_000),
      clock_interval_ms: interval(opts, :clock_interval_ms, 1_000),
      reconcile_interval_ms: interval(opts, :reconcile_interval_ms, 30_000),
      checkpoint_reader: checkpoint_reader(opts, named?),
      checkpoint_writer: checkpoint_writer(opts, named?),
      checkpoint_health: :healthy,
      sources: sources,
      availability: Map.new(Map.keys(sources), &{&1, false}),
      units: units,
      weight_facts: %{},
      weight_health: :unavailable,
      run_id: nil,
      denominator_signature: nil,
      denominator_generation: 0,
      membership_signature: nil,
      membership_generation: nil,
      membership_index: nil,
      summary_generation: 0,
      outcome_generation: 0,
      summary_snapshot: initial_summary(units),
      outcome_snapshot: initial_outcomes(sources),
      summary_lkg: nil,
      outcome_lkg: nil,
      refresh: nil,
      refresh_pending?: false,
      refresh_again?: false,
      queued_waiters: [],
      last_race_signature: nil
    }

    Checkpoint.restore(state, Checkpoint.read(state.checkpoint_reader))
  end

  @spec empty_sources() :: map()
  def empty_sources do
    %{
      run: %{},
      membership: %{
        run_id: nil,
        generation: 0,
        health: {:unavailable, :not_read},
        freshness: %{status: :stale},
        truncated?: false,
        members: []
      },
      status: %{running: [], retrying: [], idle: [], health: :unavailable, freshness: :stale},
      status_facts: [],
      activity: %{generation: 0, entries: [], health: :unavailable, freshness: :stale},
      merges: %{
        merges: [],
        health: {:unavailable, :not_read},
        reconciliation: %{status: :unknown, partial?: nil, pages_fetched: 0}
      },
      configured_repository: {:error, :configured_repository_unavailable}
    }
  end

  @doc false
  @spec run_snapshot() :: map()
  def run_snapshot do
    %{
      id: Aiur.Boot.run_id(),
      started_at: Aiur.Boot.started_at(),
      observed_at: DateTime.utc_now(),
      elapsed_ms: Aiur.Boot.elapsed_ms()
    }
  end

  defp readers(opts) do
    %{
      run: Keyword.get(opts, :run_snapshot_fun, &run_snapshot/0),
      membership: Keyword.get(opts, :membership_snapshot_fun, &CurrentRunMembership.snapshot/0),
      status: Keyword.get(opts, :status_snapshot_fun, &StatusReport.snapshot_api/0),
      status_facts: Keyword.get(opts, :status_facts_fun, &StatusReport.status_api/0),
      activity: Keyword.get(opts, :activity_snapshot_fun, &Aiur.TicketActivity.snapshots/0),
      merges: Keyword.get(opts, :recent_merges_snapshot_fun, &Aiur.RecentMergeStore.snapshot/0),
      configured_repository: Keyword.get(opts, :configured_repository_fun, &GitHubConfig.configured_repo/0)
    }
  end

  defp initial_summary(units) do
    CurrentRunSummary.Projection.snapshot(%{
      run: %{},
      units: units,
      generation: 0,
      denominator_generation: 0,
      weight_health: :unavailable
    })
    |> Map.put(:last_known_good, nil)
  end

  defp initial_outcomes(sources) do
    CurrentRunOutcomeSnapshot.Projection.snapshot(%{
      run: %{},
      membership: sources.membership,
      recent_merges: sources.merges,
      configured_repository: sources.configured_repository,
      generation: 0
    })
    |> Map.put(:last_known_good, nil)
  end

  defp checkpoint_reader(opts, named?) do
    Keyword.get_lazy(opts, :checkpoint_reader, fn -> default_checkpoint_reader(named?) end)
  end

  defp checkpoint_writer(opts, named?) do
    Keyword.get_lazy(opts, :checkpoint_writer, fn -> default_checkpoint_writer(named?) end)
  end

  defp default_checkpoint_reader(true), do: &CurrentRunMembership.projection_checkpoint/0
  defp default_checkpoint_reader(false), do: fn -> nil end
  defp default_checkpoint_writer(true), do: &CurrentRunMembership.put_projection_checkpoint/2
  defp default_checkpoint_writer(false), do: fn _, _ -> :ok end

  defp positive_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end

  defp interval(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _value -> :infinity
    end
  end
end
