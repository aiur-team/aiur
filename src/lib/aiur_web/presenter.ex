defmodule AiurWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias Aiur.{Config, DecisionHistory, Orchestrator, RecentMerge, RecentMergeStore, RunTelemetry}

  @recent_merge_limit 50

  @spec state_payload(GenServer.name(), timeout(), keyword()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms, opts \\ []) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    orchestrator
    |> orchestrator_payload(snapshot_timeout_ms)
    |> Map.put(:generated_at, generated_at)
    |> Map.merge(auxiliary_payload(opts))
  end

  defp orchestrator_payload(orchestrator, snapshot_timeout_ms) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        idle = Map.get(snapshot, :idle, [])

        %{
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            idle: length(idle)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          idle: Enum.map(idle, &idle_entry_payload/1),
          agent_totals: snapshot.agent_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  defp auxiliary_payload(opts) do
    %{
      decision_history: decision_history_payload(opts),
      recent_merges: recent_merges_payload(opts),
      analytics: analytics_payload(opts)
    }
  end

  defp decision_history_payload(opts) do
    provider = Keyword.get(opts, :decision_history_fun, fn -> DecisionHistory.list() end)

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
    "The durable merge audit is degraded; showing its last validated prefix."
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
      message: "Telemetry analytics are available after a debug telemetry run."
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
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
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

  defp issue_queue_depth(running, _idle) when is_map(running),
    do: Map.get(running, :queue_depth, 0)

  defp issue_queue_depth(nil, idle) when is_map(idle), do: Map.get(idle, :queue_depth, 0)
  defp issue_queue_depth(nil, nil), do: 0

  defp optional_recent_events(nil), do: []
  defp optional_recent_events(running), do: recent_events_payload(running)

  defp retry_error(nil), do: nil
  defp retry_error(retry), do: retry.error

  defp maybe_put_idle_payload(payload, nil), do: payload
  defp maybe_put_idle_payload(payload, idle), do: Map.put(payload, :idle, idle_entry_payload(idle))

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      tag: Map.get(entry, :tag),
      title: Map.get(entry, :title),
      url: Map.get(entry, :url),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      runtime_seconds: Map.get(entry, :runtime_seconds, 0),
      work_state: Map.get(entry, :work_state, :working),
      pause_reason: Map.get(entry, :pause_reason),
      tracker_paused: Map.get(entry, :tracker_paused, false),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      queue_depth: Map.get(entry, :queue_depth, 0),
      capabilities: Map.get(entry, :control),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      stale_for_seconds: Map.get(entry, :stale_for_seconds),
      waiting_reason: Map.get(entry, :waiting_reason, :active),
      open_decision_count: Map.get(entry, :open_decision_count, 0),
      ci: ci_payload(Map.get(entry, :ci_result)),
      review: review_status(entry.state),
      tokens: %{
        input_tokens: entry.agent_input_tokens,
        output_tokens: entry.agent_output_tokens,
        total_tokens: entry.agent_total_tokens
      }
    }
    |> maybe_put_tracker_identity(entry)
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      state: Map.get(entry, :state),
      tag: Map.get(entry, :tag),
      title: Map.get(entry, :title),
      url: Map.get(entry, :url),
      runtime_seconds: 0,
      work_state: :retrying,
      tracker_paused: false,
      waiting_reason: Map.get(entry, :waiting_reason, :backing_off),
      open_decision_count: Map.get(entry, :open_decision_count, 0),
      ci: ci_payload(Map.get(entry, :ci_result)),
      review: review_status(Map.get(entry, :state))
    }
    |> maybe_put_tracker_identity(entry)
  end

  defp idle_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      tag: Map.get(entry, :tag),
      title: Map.get(entry, :title),
      url: Map.get(entry, :url),
      runtime_seconds: 0,
      work_state: idle_work_state(entry),
      tracker_paused: Map.get(entry, :tracker_paused, false),
      queue_depth: Map.get(entry, :queue_depth, 0),
      waiting_reason: Map.get(entry, :waiting_reason, :active),
      open_decision_count: Map.get(entry, :open_decision_count, 0),
      ci: ci_payload(Map.get(entry, :ci_result)),
      review: review_status(entry.state)
    }
    |> maybe_put_tracker_identity(entry)
  end

  defp maybe_put_tracker_identity(payload, entry_or_identity) do
    identity =
      case entry_or_identity do
        %{tracker_identity: tracker_identity} -> tracker_identity
        %Aiur.TrackerIdentity{} = tracker_identity -> tracker_identity
        %{} -> nil
        tracker_identity -> tracker_identity
      end

    case identity do
      nil -> payload
      identity -> Map.put(payload, :tracker_identity, identity)
    end
  end

  # CI/PR data comes from the existing GithubCIPoller poll cadence in
  # `Aiur.Orchestrator.CiLifecycle`, cached by ticket identifier — this never
  # triggers a GitHub call of its own and is available for idle rows too
  # (a ticket can keep cycling through ci-wait polls after its agent's turn
  # ends). `nil` until a ticket has actually entered CI polling (ci-wait /
  # human-review).
  defp ci_payload(nil), do: nil

  defp ci_payload(%{} = result) do
    %{
      decision: Map.get(result, :decision),
      pr_number: Map.get(result, :pr_number),
      head_sha: Map.get(result, :head_sha)
    }
  end

  # Review status is derived from tracker state only. The unresolved-thread
  # detail behind `human-review` remains a one-shot check performed by
  # `Aiur.GitHub.HumanReviewGate` at the transition moment, not a cached
  # per-row poll target — surfacing it live per row would mean a new GitHub
  # call on every dashboard refresh, duplicating that existing check.
  defp review_status("human-review"), do: :awaiting
  defp review_status(_state), do: :not_started

  defp idle_work_state(entry) do
    if Map.get(entry, :tracker_paused, false), do: :paused, else: :idle
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      queue_depth: Map.get(running, :queue_depth, 0),
      capabilities: Map.get(running, :control),
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      stale_for_seconds: Map.get(running, :stale_for_seconds),
      waiting_reason: Map.get(running, :waiting_reason, :active),
      open_decision_count: Map.get(running, :open_decision_count, 0),
      ci: ci_payload(Map.get(running, :ci_result)),
      review: review_status(running.state),
      tokens: %{
        input_tokens: running.agent_input_tokens,
        output_tokens: running.agent_output_tokens,
        total_tokens: running.agent_total_tokens
      }
    }
    |> maybe_put_tracker_identity(running)
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path),
      state: Map.get(retry, :state),
      waiting_reason: Map.get(retry, :waiting_reason, :backing_off),
      open_decision_count: Map.get(retry, :open_decision_count, 0),
      ci: ci_payload(Map.get(retry, :ci_result)),
      review: review_status(Map.get(retry, :state))
    }
    |> maybe_put_tracker_identity(retry)
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: "no message from #{Config.agent_kind()} yet"

  defp summarize_message(%{message: message}) do
    message
    |> inspect_safely()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 140)
  end

  defp summarize_message(message), do: message |> inspect_safely() |> String.slice(0, 140)

  defp inspect_safely(value) when is_binary(value), do: value
  defp inspect_safely(value), do: inspect(value, limit: 10, printable_limit: 200)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
