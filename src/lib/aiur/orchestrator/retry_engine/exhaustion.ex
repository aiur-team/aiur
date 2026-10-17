defmodule Aiur.Orchestrator.RetryEngine.Exhaustion do
  @moduledoc "Retry exhaustion state writes and recovery."

  require Logger

  alias Aiur.Alerts
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Errors
  alias Aiur.GitHub.LocalHold
  alias Aiur.Issue
  alias Aiur.Orchestrator.AutoResume
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.RetryEngine.PollFailure
  alias Aiur.Orchestrator.ReworkGate
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Orchestrator.TrackerTasks

  defp finalize_exhausted_issue(issue_id, identifier, metadata, exhaustion_reason, opts) do
    case rework_handoff_state(identifier, metadata[:rework_head_sha], metadata) do
      {:ok, state_name} ->
        case write_after_budget_hold(identifier, state_name, opts) do
          :ok ->
            emit_rework_handoff_attention(identifier, state_name)
            :ok

          {:error, reason} ->
            Logger.warning("Rework handoff state write failed for #{identifier}: #{inspect(reason)}")
            write_exhausted_issue_state(issue_id, identifier, exhaustion_reason, opts)
        end

      :none ->
        write_exhausted_issue_state(issue_id, identifier, exhaustion_reason, opts)
    end
  end

  @doc false
  @spec start_exhausted_state_write(State.t(), String.t(), String.t(), term(), map()) :: State.t()
  def start_exhausted_state_write(state, issue_id, identifier, reason, metadata) do
    release = Map.get(state.released_claims, issue_id)
    opts = exhausted_write_options(state, issue_id)
    handoff = Map.take(metadata, [:rework_head_sha, :open_pr_fetcher, :commit_ci_status_fetcher])

    TrackerTasks.run(state, {:retry_exhausted, issue_id}, fn -> finalize_exhausted_issue(issue_id, identifier, handoff, reason, opts) end, fn current, result ->
      apply_exhausted_state_write(current, issue_id, release, result)
    end)
  end

  defp exhausted_write_options(state, issue_id) do
    case Map.get(state.last_polled_issues, issue_id) do
      %Issue{state: issue_state} when is_binary(issue_state) -> [expected_state: issue_state]
      _ -> []
    end
  end

  defp apply_exhausted_state_write(current, issue_id, release, result) do
    if Map.get(current.released_claims, issue_id) == release and not Map.has_key?(current.running, issue_id) do
      maybe_mark_observed_error_alert(current, issue_id, result == :alert_emitted)
    else
      current
    end
  end

  # On genuine retry exhaustion, surface the ticket in an Executor-visible
  # state instead of silently leaving it in `rework` with no live agent (#699).
  # `error` ("agent hit an error") is a valid state in neither the active nor
  # the terminal set, so it does not get auto-redispatched. Best-effort: a
  # failed tracker write must not crash the orchestrator.
  #
  # The terminal write is only appropriate for a *permanent* failure. When the
  # exhaustion reason is a transient infrastructure fault (DNS, timeout, TLS,
  # connection closed, rate limit, 5xx, budget hold), writing `agent:error`
  # converts a recoverable blip into a terminal ticket state; the caller
  # schedules a bounded auto-resume re-claim instead, so the ticket must stay in
  # an active state and be re-dispatched once the cause clears (#2427).
  # A raw `%Req.TransportError{}` a run surfaced is classified through the
  # transport taxonomy before the shared classifier answers, so a closed socket
  # during a run is recognized as the transient fault it is. Everything else
  # (including the formatted error string) goes straight to the classifier,
  # which treats it as permanent.
  defp transient_exhaustion_reason?(%{__struct__: struct} = reason)
       when struct in [Req.TransportError, Mint.TransportError] do
    Errors.retryable_github_error?(Errors.classify_error({:error, reason}))
  end

  defp transient_exhaustion_reason?({:issue_state_refresh_failed, reason}),
    do: transient_exhaustion_reason?(reason)

  defp transient_exhaustion_reason?(reason), do: Errors.retryable_github_error?(reason)

  # Exposed (`@doc false`) as a test seam: the distinct `{:error,
  # {:no_state_label_written, _}}` return is the F3 "do not report success for a
  # write that did not happen" contract, and the tests pin it so a regression to
  # `:ok` cannot pass the suite unnoticed (#2420).
  @doc false
  @spec move_exhausted_issue_to_error_state(String.t(), String.t(), term()) ::
          :ok | :alert_emitted | {:error, {:no_state_label_written, String.t()}}
  def move_exhausted_issue_to_error_state(issue_id, identifier, exhaustion_reason) when is_binary(identifier),
    do: write_exhausted_issue_state(issue_id, identifier, exhaustion_reason, [])

  def move_exhausted_issue_to_error_state(_issue_id, _identifier, _exhaustion_reason), do: :ok

  defp write_exhausted_issue_state(issue_id, identifier, exhaustion_reason, opts) do
    if transient_exhaustion_reason?(exhaustion_reason) do
      Logger.warning(
        "Skipping terminal error state for exhausted issue issue_id=#{issue_id} issue_identifier=#{identifier} " <>
          "reason=retry_exhausted cause=transient classifier=#{inspect(exhaustion_reason)}; automatic re-claim scheduled"
      )

      :ok
    else
      Logger.warning("Moving exhausted issue to error state: issue_id=#{issue_id} issue_identifier=#{identifier} reason=retry_exhausted caller=Aiur.Orchestrator.move_exhausted_issue_to_error_state")

      case write_after_budget_hold(identifier, "error", opts) do
        :ok ->
          message =
            "Agent entered error after retry exhaustion; automatic retry is no longer scheduled." <>
              retry_exhausted_error_suffix(exhaustion_reason)

          Alerts.emit_custom("ticket.#{identifier}.agent.attention.error-retry_exhausted", message,
            issue: identifier,
            reason: message,
            needs_attention: true,
            severity: "warning",
            # Must reach the central feed: IssueSync rediscovers the persisted
            # error cause from there after a restart.
            central: true
          )

          :alert_emitted

        {:error, {:stale_issue_state, expected, actual} = reason} when expected != actual ->
          handle_stale_exhaustion_write(issue_id, identifier, actual, reason)

        {:error, reason} ->
          Logger.warning("Failed moving exhausted issue identifier=#{identifier} to error state: #{inspect(reason)}")

          # The terminal `error` write did not happen, so report it honestly
          # instead of a false `:ok`, and alert rather than only logging (#2420):
          # a swallowed write here would leave the ticket with its active-state
          # label and no signal to the Executor that exhaustion never parked it.
          emit_error_state_write_failed(identifier, reason)
          {:error, {:no_state_label_written, identifier}}
      end
    end
  end

  defp handle_stale_exhaustion_write(issue_id, identifier, actual, reason) do
    if valid_lifecycle_state?(actual) do
      Logger.info(
        "Retry-exhaustion error write settled after ticket moved issue_id=#{issue_id} " <>
          "issue_identifier=#{identifier} state=#{inspect(actual)}"
      )

      :ok
    else
      Logger.warning("Failed moving exhausted issue identifier=#{identifier} to error state: #{inspect(reason)}")
      emit_error_state_write_failed(identifier, reason)
      {:error, {:no_state_label_written, identifier}}
    end
  end

  defp valid_lifecycle_state?(state) when is_binary(state) do
    DispatchPolicy.active_issue_state?(state, DispatchPolicy.active_state_set()) or
      DispatchPolicy.terminal_issue_state?(state, DispatchPolicy.terminal_state_set()) or
      DispatchPolicy.no_agent_work_state?(state) or
      DispatchPolicy.normalize_issue_state(state) in ["error", "human-review"]
  end

  defp valid_lifecycle_state?(_state), do: false

  defp emit_error_state_write_failed(identifier, reason) do
    Alerts.emit_custom(
      "ticket.#{identifier}.agent.attention.error-state-write-failed",
      "Agent entered retry exhaustion but the ticket could not be moved to error (#{inspect(reason)}); it keeps its active-state label and may be re-dispatched.",
      issue: identifier,
      reason: "Exhausted retry budget, but the terminal error-state write failed (#{inspect(reason)}); the ticket was not parked in error.",
      needs_attention: true,
      severity: "warning",
      central: true
    )
  end

  # Retry-exhaustion state writes are terminal and cannot be recovered by a
  # later agent turn. Keep the tracker task alive through the broker's rolling
  # Core reset, then apply the write once admission resumes. The retry task has
  # no fixed task timeout for this reason; LocalHold still bounds each wait and
  # limits repeated holds.
  defp write_after_budget_hold(identifier, state_name, opts) do
    LocalHold.run(
      fn -> TicketTransition.write_state(identifier, state_name, Keyword.put(opts, :writer, :retry_engine)) end,
      LocalHold.caller_opts(opts) |> Keyword.put(:max_wait_ms, 3_600_000)
    )
  end

  defp rework_handoff_state(identifier, original_head, metadata) do
    opts = [
      open_pr_fetcher: Map.get(metadata, :open_pr_fetcher, &Aiur.CodeHost.fetch_open_pull_request_for_branch/1),
      commit_ci_status_fetcher: Map.get(metadata, :commit_ci_status_fetcher, &GitHubClient.fetch_commit_ci_status/1)
    ]

    case ReworkGate.stopped_agent_handoff(identifier, original_head, opts) do
      {:handoff, state_name} -> {:ok, state_name}
      :none -> :none
    end
  end

  defp emit_rework_handoff_attention(identifier, state_name) do
    message = "Agent exhausted retries without handing off after pushing rework for #{identifier}; moved the ticket to agent:#{state_name}."

    Alerts.emit_custom("ticket.#{identifier}.agent.rework_handoff", message,
      issue: identifier,
      reason: message,
      needs_attention: true,
      severity: "info"
    )
  end

  defp maybe_mark_observed_error_alert(state, issue_id, true) do
    %{
      state
      | observed_error_alerts: MapSet.put(state.observed_error_alerts, issue_id),
        observed_error_alert_causes: Map.put(state.observed_error_alert_causes, issue_id, :retry_exhausted)
    }
  end

  defp maybe_mark_observed_error_alert(state, _issue_id, false), do: state

  defp retry_exhausted_error_suffix(error) when is_binary(error) and error != "", do: " Last error: #{error}"
  defp retry_exhausted_error_suffix(error) when is_atom(error) or is_tuple(error) or is_map(error), do: " Last error: #{inspect(error)}"
  defp retry_exhausted_error_suffix(_error), do: ""

  # Schedules a bounded automatic re-dispatch when an exhaustion cause is a
  # classifiably transient infrastructure fault (#1453). Returns `state`
  # unchanged for terminal causes, operator pauses, or when the latch is
  # disabled/irrelevant — the ticket parks for normal (operator) recovery.
  @doc false
  @spec maybe_schedule_transient_auto_resume(State.t(), String.t(), term()) :: State.t()
  def maybe_schedule_transient_auto_resume(%State{} = state, issue_id, reason)
      when is_binary(issue_id) do
    case AutoResume.classify(reason) do
      nil ->
        state

      cause ->
        Logger.info("Scheduling transient auto-resume issue_id=#{issue_id} cause=#{cause} reason=#{inspect(reason)}")

        AutoResume.schedule(state, issue_id, cause, PollFailure.recovery_delay_options(reason))
    end
  end

  # The cause passed to `AutoResume.classify/1` at retry exhaustion: the
  # structured transient reason when one was recorded, else the formatted error
  # string (which classifies as terminal, so an infra fault with no structured
  # record still parks for operator recovery rather than auto-resuming on an
  # unclassifiable cause).
  @doc false
  @spec effective_exhaustion_reason(term(), term()) :: term()
  def effective_exhaustion_reason(nil, error), do: error
  def effective_exhaustion_reason(transient_reason, _error), do: transient_reason

  # The generic "retry budget exhausted" alert text alone forces the operator
  # to grep the daemon log to find the actual failure (e.g. a workspace
  # provisioning error); fold the last recorded error into the operator-facing
  # message so it is visible without leaving the alert.
  @doc false
  @spec retry_exhausted_alert_message(term()) :: String.t()
  def retry_exhausted_alert_message(error) when is_binary(error) do
    "Agent retry attempts were exhausted; the ticket needs Executor review. Last error: #{error}"
  end

  def retry_exhausted_alert_message(_error) do
    "Agent retry attempts were exhausted; the ticket needs Executor review."
  end
end
