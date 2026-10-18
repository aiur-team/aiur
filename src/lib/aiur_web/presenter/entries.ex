defmodule AiurWeb.Presenter.Entries do
  @moduledoc false

  alias Aiur.Config
  alias Aiur.Orchestrator.WaitingReason

  @spec running_entry_payload(map()) :: map()
  def running_entry_payload(entry) do
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
      adopted_from: Map.get(entry, :adopted_from),
      repl_attach_command: Map.get(entry, :repl_attach_command),
      live_conversation: Map.get(entry, :live_conversation),
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
      waiting: WaitingReason.public_wait(entry),
      open_decision_count: Map.get(entry, :open_decision_count, 0),
      open_decision_count_health: Map.get(entry, :open_decision_count_health, :unknown),
      ci: ci_payload(Map.get(entry, :ci_result)),
      review: review_status(entry.state)
    }
    |> Map.merge(public_execution_facts(entry))
    |> maybe_put_tracker_identity(entry)
  end

  @spec retry_entry_payload(map()) :: map()
  def retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      waiting: WaitingReason.public_wait(entry),
      error: entry.error,
      last_failure_at: iso8601(Map.get(entry, :last_failure_at)),
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
      open_decision_count_health: Map.get(entry, :open_decision_count_health, :unknown),
      ci: ci_payload(Map.get(entry, :ci_result)),
      review: review_status(Map.get(entry, :state))
    }
    |> Map.merge(public_execution_facts(entry))
    |> maybe_put_tracker_identity(entry)
  end

  @spec idle_entry_payload(map()) :: map()
  def idle_entry_payload(entry) do
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
      waiting: WaitingReason.public_wait(entry),
      open_decision_count: Map.get(entry, :open_decision_count, 0),
      open_decision_count_health: Map.get(entry, :open_decision_count_health, :unknown),
      ci: ci_payload(Map.get(entry, :ci_result)),
      review: review_status(entry.state)
    }
    |> Map.merge(public_execution_facts(entry))
    |> maybe_put_tracker_identity(entry)
  end

  defp public_execution_facts(entry) do
    Map.take(entry, [
      :backend,
      :agent_family,
      :requested_model,
      :resolved_model,
      :effort,
      :complexity,
      :build_lane,
      :labels,
      :observed_at,
      :age_ms,
      :retry_scope
    ])
  end

  @spec maybe_put_tracker_identity(map(), term()) :: map()
  def maybe_put_tracker_identity(payload, entry_or_identity) do
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

  # CI evidence comes from the poll cache; presentation never triggers a read.
  defp ci_payload(nil), do: nil

  defp ci_payload(%{} = result) do
    %{
      decision: Map.get(result, :decision),
      pr_number: Map.get(result, :pr_number),
      head_sha: Map.get(result, :head_sha),
      draft?: Map.get(result, :draft?) == true
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

  @spec running_issue_payload(map()) :: map()
  def running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      adopted_from: Map.get(running, :adopted_from),
      live_conversation: Map.get(running, :live_conversation),
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
      open_decision_count_health: Map.get(running, :open_decision_count_health, :unknown),
      ci: ci_payload(Map.get(running, :ci_result)),
      review: review_status(running.state)
    }
    |> maybe_put_tracker_identity(running)
  end

  @spec public_agent_totals(term()) :: map()
  def public_agent_totals(totals) when is_map(totals),
    do: %{seconds_running: Map.get(totals, :seconds_running, 0)}

  def public_agent_totals(_totals), do: %{seconds_running: 0}

  # Preserve authoritative capacity; invalid counts stay unknown.
  @spec capacity_payload(term()) :: map() | nil
  def capacity_payload(%{} = capacity) do
    %{
      active: non_negative_integer(Map.get(capacity, :active)),
      max: positive_integer(Map.get(capacity, :max)),
      configured: positive_integer(Map.get(capacity, :configured)),
      session_override?: Map.get(capacity, :session_override?) == true,
      draining?: Map.get(capacity, :draining?) == true,
      observed_at: Map.get(capacity, :observed_at),
      age_ms: Map.get(capacity, :age_ms)
    }
    |> Map.merge(Map.take(capacity, [:occupied, :effective, :available, :load, :load_threshold, :schedulers, :queued_demand?, :dispatch_observation]))
  end

  def capacity_payload(_capacity), do: nil

  # Preserve admission signals so capacity holds remain distinguishable from idle fleets.
  @spec capacity_hold_payload(term()) :: map()
  def capacity_hold_payload(%{held?: true} = hold) do
    %{
      held?: true,
      signal: Map.get(hold, :signal),
      measured: Map.get(hold, :measured),
      threshold: Map.get(hold, :threshold),
      held_for_seconds: non_negative_integer(Map.get(hold, :held_for_seconds)),
      # Forwarded rather than recomputed: the orchestrator stamped the sample,
      # and how long the hold has lasted is not how old its measurement is. A
      # consumer that shows `measured` without this cannot tell a current
      # reading from one latched minutes earlier (#2527).
      sample_age_seconds: non_negative_integer(Map.get(hold, :sample_age_seconds))
    }
  end

  def capacity_hold_payload(_hold),
    do: %{held?: false, signal: nil, measured: nil, threshold: nil, held_for_seconds: 0, sample_age_seconds: nil}

  @spec dispatch_hold_payload(term()) :: map()
  def dispatch_hold_payload(%{held?: true} = hold) do
    %{
      held?: true,
      reason: Map.get(hold, :reason),
      detail: Map.get(hold, :detail),
      held_for_seconds: non_negative_integer(Map.get(hold, :held_for_seconds))
    }
  end

  def dispatch_hold_payload(_hold),
    do: %{held?: false, reason: nil, detail: nil, held_for_seconds: 0}

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  @spec retry_issue_payload(map()) :: map()
  def retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path),
      state: Map.get(retry, :state),
      waiting_reason: Map.get(retry, :waiting_reason, :backing_off),
      open_decision_count: Map.get(retry, :open_decision_count, 0),
      open_decision_count_health: Map.get(retry, :open_decision_count_health, :unknown),
      ci: ci_payload(Map.get(retry, :ci_result)),
      review: review_status(Map.get(retry, :state))
    }
    |> maybe_put_tracker_identity(retry)
  end

  @spec workspace_path(String.t(), map() | nil, map() | nil) :: String.t() | nil
  def workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  @spec workspace_host(map() | nil, map() | nil) :: String.t() | nil
  def workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  @spec recent_events_payload(map()) :: [map()]
  def recent_events_payload(running) do
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
