defmodule AiurWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias Aiur.{Config, Orchestrator}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        idle = Map.get(snapshot, :idle, [])

        %{
          generated_at: generated_at,
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
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        idle = Enum.find(Map.get(snapshot, :idle, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(idle) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, idle)}
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

  defp issue_payload_body(issue_identifier, running, retry, idle) do
    payload = %{
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
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      capabilities: running && Map.get(running, :control),
      queue: %{
        depth:
          (running && Map.get(running, :queue_depth)) ||
            (idle && Map.get(idle, :queue_depth)) || 0
      },
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }

    if idle, do: Map.put(payload, :idle, idle_entry_payload(idle)), else: payload
  end

  defp issue_id_from_entries(running, retry, idle),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (idle && idle.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _idle) when is_map(running), do: "running"
  defp issue_status(_running, retry, _idle) when is_map(retry), do: "retrying"
  defp issue_status(_running, _retry, idle) when is_map(idle), do: "idle"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
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
      waiting_reason: Map.get(entry, :waiting_reason, :backing_off),
      open_decision_count: Map.get(entry, :open_decision_count, 0),
      ci: ci_payload(Map.get(entry, :ci_result)),
      review: review_status(Map.get(entry, :state))
    }
  end

  defp idle_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      tag: Map.get(entry, :tag),
      title: Map.get(entry, :title),
      url: Map.get(entry, :url),
      queue_depth: Map.get(entry, :queue_depth, 0),
      waiting_reason: Map.get(entry, :waiting_reason, :active),
      open_decision_count: Map.get(entry, :open_decision_count, 0),
      ci: ci_payload(Map.get(entry, :ci_result)),
      review: review_status(entry.state)
    }
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
