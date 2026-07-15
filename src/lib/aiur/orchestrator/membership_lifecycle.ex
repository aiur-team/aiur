defmodule Aiur.Orchestrator.MembershipLifecycle do
  @moduledoc false

  require Logger

  alias Aiur.{CurrentRunMembership, Issue, TrackerIdentity}

  @membership_observe_timeout 5_000

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
