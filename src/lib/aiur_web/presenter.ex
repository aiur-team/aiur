defmodule AiurWeb.Presenter do
  @moduledoc "Shared projections for the observability API and dashboard."

  import AiurWeb.Presenter.Entries,
    only: [
      running_entry_payload: 1,
      retry_entry_payload: 1,
      idle_entry_payload: 1,
      maybe_put_tracker_identity: 2,
      running_issue_payload: 1,
      public_agent_totals: 1,
      capacity_payload: 1,
      capacity_hold_payload: 1,
      dispatch_hold_payload: 1,
      retry_issue_payload: 1,
      workspace_path: 3,
      workspace_host: 2,
      recent_events_payload: 1
    ]

  alias Aiur.{Commands, Orchestrator, RecentMerge, RecentMergeStore, RunTelemetry}

  @recent_merge_limit 50
  @spec state_payload(GenServer.name(), timeout(), keyword()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms, opts \\ []) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    orchestrator
    |> orchestrator_payload(snapshot_timeout_ms)
    |> Map.put(:generated_at, generated_at)
    |> Map.merge(auxiliary_payload(opts))
  end

  @doc "Returns the current dashboard navigation contract for telemetry analytics."
  @spec analytics_navigation(keyword()) :: map()
  def analytics_navigation(opts \\ []), do: analytics_payload(opts)

  defp orchestrator_payload(orchestrator, snapshot_timeout_ms) do
    case Orchestrator.dashboard_snapshot(orchestrator, snapshot_timeout_ms) do
      {status, snapshot, freshness} when status in [:current, :stale] ->
        snapshot_payload(snapshot, freshness)

      :snapshot_unpublished ->
        %{error: %{code: "snapshot_unpublished", message: "No fleet snapshot published yet"}}

      :orchestrator_unavailable ->
        %{error: %{code: "orchestrator_unavailable", message: "Orchestrator is unavailable"}}
    end
  end

  defp snapshot_payload(snapshot, freshness) do
    idle = Map.get(snapshot, :idle, [])
    globally_paused = Map.get(snapshot, :globally_paused, false) == true

    payload = %{
      counts: %{
        running: length(snapshot.running),
        retrying: length(snapshot.retrying),
        idle: length(idle)
      },
      running: Enum.map(snapshot.running, &running_entry_payload/1),
      retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
      idle: Enum.map(idle, &idle_entry_payload/1),
      agent_totals: public_agent_totals(snapshot.agent_totals),
      capacity: capacity_payload(Map.get(snapshot, :capacity)),
      capacity_hold: capacity_hold_payload(Map.get(snapshot, :capacity_hold)),
      dispatch_hold: dispatch_hold_payload(Map.get(snapshot, :dispatch_hold)),
      polling: polling_payload(Map.get(snapshot, :polling)),
      globally_paused: globally_paused,
      observations: Map.get(snapshot, :observations),
      daemon_started_at: Map.get(snapshot, :daemon_started_at)
    }

    Map.put(payload, :snapshot_freshness, freshness)
  end

  defp polling_payload(%{} = polling) do
    Map.take(polling, [
      :checking?,
      :next_poll_in_ms,
      :poll_interval_ms,
      :effective_interval_ms,
      :idle_backoff,
      :class_intervals
    ])
  end

  defp polling_payload(_polling), do: nil

  defp auxiliary_payload(opts) do
    %{
      decision_history: decision_history_payload(opts),
      recent_merges: recent_merges_payload(opts),
      analytics: analytics_payload(opts)
    }
  end

  defp decision_history_payload(opts) do
    provider = Keyword.get(opts, :decision_history_fun, fn -> Commands.history() end)

    case safe_call(provider) do
      {:ok, entries} when is_list(entries) ->
        %{status: :available, entries: entries, message: nil}

      _other ->
        %{
          status: :unavailable,
          entries: [],
          message: "Decision history is temporarily unavailable."
        }
    end
  end

  defp recent_merges_payload(opts) do
    provider = Keyword.get(opts, :recent_merge_snapshot_fun, fn -> RecentMergeStore.snapshot() end)

    case safe_call(provider) do
      {:ok, %{merges: merges, health: health, reconciliation: reconciliation}}
      when is_list(merges) and is_map(reconciliation) ->
        %{
          status: if(health == :writable, do: :available, else: :degraded),
          entries:
            merges
            |> Enum.map(&recent_merge_payload/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.take(@recent_merge_limit),
          health: health,
          reconciliation: reconciliation,
          message: recent_merge_message(health)
        }

      _other ->
        %{
          status: :unavailable,
          entries: [],
          health: :unavailable,
          reconciliation: %{status: :unknown, partial?: nil, pages_fetched: 0},
          message: "Recent repository merges are temporarily unavailable."
        }
    end
  end

  defp recent_merge_payload(%RecentMerge{} = merge) do
    %{
      id: merge.id,
      repository: merge.repository,
      number: merge.number,
      title: merge.title,
      summary: merge.summary,
      url: merge.url,
      head_ref: merge.head_ref,
      head_sha: merge.head_sha,
      merge_commit_sha: merge.merge_commit_sha,
      ticket_id: merge.ticket_id,
      merged_by: merge.merged_by,
      merged_at: DateTime.to_iso8601(merge.merged_at),
      observation_source: merge.observation_source,
      backfilled?: merge.backfilled?,
      live_observed?: merge.live_observed?,
      observed_run_id: merge.observed_run_id
    }
  end

  defp recent_merge_payload(_merge), do: nil

  defp recent_merge_message(:writable), do: nil

  defp recent_merge_message(_health) do
    "Showing a partial merge history."
  end

  defp analytics_payload(opts) do
    provider = Keyword.get(opts, :telemetry_file_fun, &RunTelemetry.telemetry_file/0)

    case safe_call(provider) do
      {:ok, path} when is_binary(path) ->
        if File.regular?(path) do
          %{
            available?: true,
            path: "/analytics",
            message: "Open the separate durable telemetry report."
          }
        else
          analytics_unavailable()
        end

      _other ->
        analytics_unavailable()
    end
  end

  defp analytics_unavailable do
    %{
      available?: false,
      path: nil,
      message: "Telemetry analytics are available after a run telemetry run."
    }
  end

  defp safe_call(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.dashboard_snapshot(orchestrator, snapshot_timeout_ms) do
      {_status, snapshot, _freshness} ->
        running_matches = Enum.filter(snapshot.running, &(&1.identifier == issue_identifier))
        retry_matches = Enum.filter(snapshot.retrying, &(&1.identifier == issue_identifier))
        idle_matches = Enum.filter(Map.get(snapshot, :idle, []), &(&1.identifier == issue_identifier))
        entries = running_matches ++ retry_matches ++ idle_matches

        with [_issue_id] <- Enum.uniq_by(entries, & &1.issue_id),
             {:ok, tracker_identity} <- consistent_tracker_identity(entries) do
          {:ok,
           issue_payload_body(
             issue_identifier,
             List.first(running_matches),
             List.first(retry_matches),
             List.first(idle_matches),
             tracker_identity
           )}
        else
          _ -> {:error, :issue_not_found}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, idle, tracker_identity) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, idle),
      status: issue_status(running, retry, idle),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: optional_running_payload(running),
      retry: optional_retry_payload(retry),
      capabilities: issue_capabilities(running),
      queue: %{
        depth: issue_queue_depth(running, idle)
      },
      logs: %{
        codex_session_logs: []
      },
      recent_events: optional_recent_events(running),
      last_error: retry_error(retry),
      tracked: %{}
    }
    |> maybe_put_tracker_identity(tracker_identity)
    |> maybe_put_idle_payload(idle)
  end

  defp issue_id_from_entries(running, retry, idle),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (idle && idle.issue_id)

  defp consistent_tracker_identity(entries) do
    case entries |> Enum.map(&Map.get(&1, :tracker_identity)) |> Enum.uniq() do
      [identity] -> {:ok, identity}
      _ -> :error
    end
  end

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _idle) when is_map(running), do: "running"
  defp issue_status(_running, retry, _idle) when is_map(retry), do: "retrying"
  defp issue_status(_running, _retry, idle) when is_map(idle), do: "idle"

  defp optional_running_payload(nil), do: nil
  defp optional_running_payload(running), do: running_issue_payload(running)

  defp optional_retry_payload(nil), do: nil
  defp optional_retry_payload(retry), do: retry_issue_payload(retry)

  defp issue_capabilities(nil), do: nil
  defp issue_capabilities(running), do: Map.get(running, :control)

  defp issue_queue_depth(running, _idle) when is_map(running), do: Map.get(running, :queue_depth, 0)

  defp issue_queue_depth(nil, idle) when is_map(idle), do: Map.get(idle, :queue_depth, 0)
  defp issue_queue_depth(nil, nil), do: 0

  defp optional_recent_events(nil), do: []
  defp optional_recent_events(running), do: recent_events_payload(running)

  defp retry_error(nil), do: nil
  defp retry_error(retry), do: retry.error

  defp maybe_put_idle_payload(payload, nil), do: payload
  defp maybe_put_idle_payload(payload, idle), do: Map.put(payload, :idle, idle_entry_payload(idle))
end
