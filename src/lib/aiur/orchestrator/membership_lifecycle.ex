defmodule Aiur.Orchestrator.MembershipLifecycle do
  @moduledoc false

  require Logger

  alias Aiur.{CurrentRunMembership, Issue, TrackerIdentity}

  @membership_observe_timeout 5_000

  @spec record(term(), atom(), (TrackerIdentity.t(), atom() -> term())) :: :ok
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
  @spec observe(TrackerIdentity.t(), atom()) :: :ok
  def observe(identity, lifecycle) do
    case CurrentRunMembership.observe(identity, lifecycle,
           source: :tracker,
           timeout: @membership_observe_timeout
         ) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("aiur_current_run_membership phase=lifecycle_observation_failed reason=#{inspect(reason)}")
    end
  rescue
    error ->
      Logger.warning("aiur_current_run_membership phase=lifecycle_observation_failed error=#{Exception.message(error)}")
  catch
    kind, reason ->
      Logger.warning("aiur_current_run_membership phase=lifecycle_observation_failed reason=#{inspect({kind, reason})}")
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
        Logger.warning("aiur_current_run_membership phase=lifecycle_observation_failed reason=#{inspect(reason)}")

      result ->
        Logger.warning("aiur_current_run_membership phase=lifecycle_observation_failed result=#{inspect(result)}")
    end
  rescue
    error ->
      Logger.warning("aiur_current_run_membership phase=lifecycle_observation_failed error=#{Exception.message(error)}")
  catch
    kind, reason ->
      Logger.warning("aiur_current_run_membership phase=lifecycle_observation_failed reason=#{inspect({kind, reason})}")
  end
end
