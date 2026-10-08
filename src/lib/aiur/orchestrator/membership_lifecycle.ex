defmodule Aiur.Orchestrator.MembershipLifecycle do
  @moduledoc false

  require Logger

  alias Aiur.{Alerts, CurrentRunMembership, Issue, TrackerIdentity}
  alias Aiur.Orchestrator.State

  @membership_observe_timeout 5_000
  @terminal_verification_attempt_limit 5

  @spec record(term(), atom(), (TrackerIdentity.t(), atom() -> term())) ::
          :ok | {:error, :membership_observation_failed}
  def record(issue, lifecycle, observe_membership_fun \\ &observe/2)

  def record(%Issue{} = issue, lifecycle, observe_membership_fun)
      when is_function(observe_membership_fun, 2) do
    case Issue.tracker_identity(issue) do
      %TrackerIdentity{} = identity ->
        if TrackerIdentity.joinable?(identity),
          do: safely_observe(observe_membership_fun, identity, lifecycle),
          else: :ok

      _ ->
        :ok
    end
  end

  def record(_issue, _lifecycle, _observe_membership_fun), do: :ok

  @doc false
  @spec bound_terminal_verification(State.t(), [String.t()], [String.t()]) :: {State.t(), [String.t()]}
  def bound_terminal_verification(state, attempted_ids, pending_ids) do
    {attempts, abandoned_ids} =
      Enum.reduce(attempted_ids, {state.terminal_verification_attempts, []}, fn id, {attempts, abandoned} ->
        count = Map.get(attempts, id, 0) + 1

        cond do
          id not in pending_ids ->
            {Map.delete(attempts, id), abandoned}

          count < @terminal_verification_attempt_limit ->
            {Map.put(attempts, id, count), abandoned}

          true ->
            alert_terminal_verification_abandoned(Map.fetch!(state.last_polled_issues, id), count)
            {Map.delete(attempts, id), [id | abandoned]}
        end
      end)

    {%{state | terminal_verification_attempts: attempts}, pending_ids -- abandoned_ids}
  end

  @doc false
  @spec observe(TrackerIdentity.t(), atom()) :: :ok | {:error, :membership_observation_failed}
  def observe(identity, lifecycle) do
    case CurrentRunMembership.observe(identity, lifecycle,
           source: :tracker,
           timeout: @membership_observe_timeout
         ) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        log_observation_failure(reason)
        {:error, :membership_observation_failed}
    end
  rescue
    error ->
      log_observation_failure(error)
      {:error, :membership_observation_failed}
  catch
    kind, reason ->
      log_observation_failure({kind, reason})
      {:error, :membership_observation_failed}
  end

  @doc false
  @spec terminal_lifecycle(term()) :: :completed | :cancelled
  def terminal_lifecycle(state) when is_binary(state) do
    if String.downcase(String.trim(state)) in ["cancelled", "canceled"],
      do: :cancelled,
      else: :completed
  end

  def terminal_lifecycle(_state), do: :completed

  defp alert_terminal_verification_abandoned(issue, count) do
    Alerts.emit_system("ticket.#{issue.identifier}.terminal_verification_abandoned",
      issue: issue.identifier,
      message: "Terminal verification abandoned for #{issue.identifier} after #{count} attempts.",
      reason: "Tracker refresh or membership persistence remained unresolved after #{count} attempts; stopped retaining the ticket.",
      needs_attention: true,
      severity: "warning",
      central: true
    )
  end

  defp safely_observe(observe_membership_fun, identity, lifecycle) do
    case observe_membership_fun.(identity, lifecycle) do
      :ok ->
        :ok

      {:ok, _result} ->
        :ok

      {:error, reason} ->
        log_observation_failure(reason)
        {:error, :membership_observation_failed}

      result ->
        log_observation_failure(result)
        {:error, :membership_observation_failed}
    end
  rescue
    error ->
      log_observation_failure(error)
      {:error, :membership_observation_failed}
  catch
    kind, reason ->
      log_observation_failure({kind, reason})
      {:error, :membership_observation_failed}
  end

  defp log_observation_failure(_reason) do
    Logger.warning("aiur_current_run_membership phase=lifecycle_observation_failed code=membership_observation_failed")
  end
end
