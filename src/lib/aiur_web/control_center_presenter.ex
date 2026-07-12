defmodule AiurWeb.ControlCenterPresenter do
  @moduledoc """
  Composes the Operator Control Center's read model from independent domain
  providers. A failed optional provider degrades only its own surface.
  """

  alias Aiur.{Decision, DecisionStore}
  alias AiurWeb.Presenter

  @urgency_rank %{low: 0, normal: 1, high: 2, critical: 3}

  @spec state_payload(GenServer.name(), timeout(), keyword()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms, opts \\ []) do
    decision_store = Keyword.get(opts, :decision_store, DecisionStore)
    recent_merge_store = Keyword.get(opts, :recent_merge_store, Aiur.RecentMergeStore)

    presenter_opts = [
      decision_history_fun: fn ->
        required_provider_call(Aiur.DecisionHistory, :list, [[server: decision_store]])
      end,
      recent_merge_snapshot_fun: fn ->
        required_provider_call(Aiur.RecentMergeStore, :snapshot, [recent_merge_store])
      end
    ]

    fleet_fun =
      Keyword.get(opts, :fleet_fun, fn ->
        Presenter.state_payload(orchestrator, snapshot_timeout_ms, presenter_opts)
      end)

    decisions_fun = Keyword.get(opts, :decisions_fun, fn -> DecisionStore.list(decision_store) end)

    {fleet, fleet_health} = safe_read(fleet_fun, unavailable_fleet())
    {decisions, decisions_health} = safe_read(decisions_fun, [])
    {history, history_health} = history_read(fleet, opts)
    {recent_merges, recent_outcomes_health} = recent_merges_read(fleet, opts)

    fleet
    |> compose(decisions, history, recent_merges)
    |> Map.put(:provider_health, %{
      fleet: fleet_health,
      decisions: decisions_health,
      history: history_health,
      recent_outcomes: recent_outcomes_health
    })
  end

  @spec compose(map(), [Decision.t()], [map()], map()) :: map()
  def compose(fleet, decisions, history, recent_merges)
      when is_map(fleet) and is_list(decisions) and is_list(history) and is_map(recent_merges) do
    decision_rows = decisions |> Enum.map(&decision_row/1) |> sort_decisions()
    recent_outcomes = normalize_recent_outcomes(recent_merges)

    %{
      generated_at: Map.get(fleet, :generated_at),
      fleet: Map.drop(fleet, [:decision_history, :recent_merges, :analytics]),
      decisions: decision_rows,
      history: Enum.map(history, &history_row/1),
      recent_outcomes: recent_outcomes,
      recent_outcomes_health: Map.get(recent_merges, :health),
      recent_outcomes_reconciliation: Map.get(recent_merges, :reconciliation),
      analytics: analytics(Map.get(fleet, :analytics)),
      overview: overview(fleet, decision_rows, recent_outcomes),
      provider_health: %{fleet: :ok, decisions: :ok, history: :ok, recent_outcomes: :ok}
    }
  end

  @spec find_decision(map(), String.t()) :: {:ok, map()} | :error
  def find_decision(%{decisions: decisions}, decision_id) when is_list(decisions) and is_binary(decision_id) do
    case Enum.find(decisions, &(&1.decision_id == decision_id)) do
      nil -> :error
      decision -> {:ok, decision}
    end
  end

  def find_decision(_payload, _decision_id), do: :error

  defp decision_row(%Decision{} = decision) do
    %{
      decision_id: decision.decision_id,
      version: decision.version,
      ticket: decision.ticket,
      source: decision.source,
      kind: decision.kind,
      authority: decision.authority,
      urgency: decision.urgency,
      blocking: decision.blocking,
      reversibility: decision.reversibility,
      question: decision.question,
      context: %{
        short: Map.get(decision.context, :short_summary),
        long_markdown: Map.get(decision.context, :long_context_markdown)
      },
      options: Enum.map(decision.options, &option_row/1),
      recommendation: decision.recommendation,
      consequence_of_delay: decision.consequence_of_delay,
      artifacts: decision.artifacts,
      created_at: decision.created_at,
      source_created_at: decision.source_created_at,
      lifecycle: lifecycle(decision)
    }
  end

  defp option_row(option) do
    %{
      id: Map.get(option, :id),
      label: Map.get(option, :label),
      description: Map.get(option, :description),
      benefits: Map.get(option, :benefits),
      drawbacks: Map.get(option, :drawbacks),
      risk: Map.get(option, :risk)
    }
  end

  # OCC-1 records an accepted request. OCC-3 owns every later lifecycle state;
  # never infer delivery from the existence of the Decision itself.
  defp lifecycle(decision), do: Map.get(decision, :lifecycle, :recorded)

  defp sort_decisions(decisions) do
    Enum.sort_by(decisions, fn decision ->
      {not decision.blocking, -Map.get(@urgency_rank, decision.urgency, 0), datetime_sort_key(decision.created_at), decision.decision_id}
    end)
  end

  defp datetime_sort_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort_key(_datetime), do: 0

  defp overview(fleet, decisions, recent_outcomes) do
    counts = Map.get(fleet, :counts, %{})

    %{
      blocking_decisions: Enum.count(decisions, &(&1.blocking and &1.lifecycle == :recorded)),
      running: Map.get(counts, :running, 0),
      queued_or_retrying: Map.get(counts, :idle, 0) + Map.get(counts, :retrying, 0),
      recent_repository_merges: length(recent_outcomes)
    }
  end

  defp history_row(entry) do
    follow_up = Map.get(entry, :follow_up, %{})

    %{
      decision_id: Map.get(entry, :decision_id),
      ticket: Map.get(entry, :ticket),
      question: Map.get(entry, :question),
      source_version: Map.get(entry, :source_version),
      changed_at: Map.get(entry, :changed_at),
      change: Map.get(entry, :change),
      actor: Map.get(entry, :actor),
      action_id: Map.get(entry, :action_id),
      prior_action_id: Map.get(entry, :prior_action_id),
      revision_sequence: Map.get(entry, :revision_sequence),
      revision_result: Map.get(entry, :revision_result),
      choice: Map.get(entry, :choice),
      rationale: Map.get(entry, :rationale),
      dispatch_result: Map.get(entry, :dispatch_result),
      acknowledgement_result: Map.get(entry, :acknowledgement_result),
      revision_of: Map.get(entry, :revision_of),
      superseded_by: Map.get(entry, :superseded_by),
      revised?: Map.get(entry, :revised?, false),
      follow_up: follow_up,
      follow_up_required: Map.get(follow_up, :required?, Map.get(entry, :follow_up_required, false)),
      follow_up_handled: Map.get(follow_up, :handled?, Map.get(entry, :follow_up_handled, false))
    }
  end

  defp normalize_recent_outcomes(%{merges: merges}) when is_list(merges), do: Enum.map(merges, &recent_outcome_row/1)
  defp normalize_recent_outcomes(_recent_merges), do: []

  defp recent_outcome_row(merge) do
    %{
      repository: Map.get(merge, :repository),
      number: Map.get(merge, :number),
      title: Map.get(merge, :title),
      summary: Map.get(merge, :summary),
      url: Map.get(merge, :url),
      head_ref: Map.get(merge, :head_ref),
      head_sha: Map.get(merge, :head_sha),
      merge_commit_sha: Map.get(merge, :merge_commit_sha),
      ticket_id: Map.get(merge, :ticket_id),
      merged_by: Map.get(merge, :merged_by),
      merged_at: Map.get(merge, :merged_at),
      observation_source: Map.get(merge, :observation_source),
      backfilled?: Map.get(merge, :backfilled?, false),
      live_observed?: Map.get(merge, :live_observed?, false),
      observed_run_id: Map.get(merge, :observed_run_id)
    }
  end

  defp required_provider_call(module, function, arguments) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(arguments)) do
      apply(module, function, arguments)
    else
      exit({:provider_unavailable, module, function})
    end
  end

  defp history_read(fleet, opts) do
    case Keyword.fetch(opts, :history_fun) do
      {:ok, fun} -> safe_read(fun, [])
      :error -> embedded_entries(Map.get(fleet, :decision_history), [])
    end
  end

  defp recent_merges_read(fleet, opts) do
    case Keyword.fetch(opts, :recent_merges_fun) do
      {:ok, fun} ->
        safe_read(fun, unavailable_recent_merges())

      :error ->
        case Map.get(fleet, :recent_merges) do
          %{entries: entries, health: health, reconciliation: reconciliation} = provider
          when is_list(entries) and is_map(reconciliation) ->
            {%{merges: entries, health: health, reconciliation: reconciliation}, provider_health(Map.get(provider, :status))}

          _other ->
            {unavailable_recent_merges(), :unavailable}
        end
    end
  end

  defp embedded_entries(%{entries: entries} = provider, _fallback) when is_list(entries) do
    {entries, provider_health(Map.get(provider, :status))}
  end

  defp embedded_entries(_provider, fallback), do: {fallback, :unavailable}

  defp provider_health(status) when status in [:available, :ok], do: :ok
  defp provider_health(:degraded), do: :degraded
  defp provider_health(_status), do: :unavailable

  defp analytics(%{available?: available?, path: path, message: message}) when is_boolean(available?) do
    %{available?: available?, path: path, message: message}
  end

  defp analytics(_analytics) do
    %{available?: false, path: nil, message: "Telemetry analytics are unavailable."}
  end

  defp safe_read(fun, fallback) when is_function(fun, 0) do
    {fun.(), :ok}
  rescue
    _error -> {fallback, :unavailable}
  catch
    :exit, _reason -> {fallback, :unavailable}
    _kind, _reason -> {fallback, :unavailable}
  end

  defp unavailable_fleet do
    %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"},
      counts: %{running: 0, retrying: 0, idle: 0},
      running: [],
      retrying: [],
      idle: [],
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }
  end

  defp unavailable_recent_merges do
    %{merges: [], health: :unavailable, reconciliation: %{status: :unavailable, partial?: true}}
  end
end
